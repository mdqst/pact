{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MonadFailDesugaring        #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE MultiWayIf                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE ViewPatterns               #-}

module Pact.Analyze.Translate where

import           Control.Applicative        ((<|>), Alternative (empty))
import           Control.Lens               (Prism', at, cons, makeLenses,
                                             preview, prism', review, view,
                                             (%~), (.~), (<&>), (?~), (^.),
                                             (^?), _1, _2)
import           Control.Monad              (MonadPlus (mzero), (>=>))
import           Control.Monad.Except       (Except, MonadError, throwError)
import           Control.Monad.Fail         (MonadFail (fail))
import           Control.Monad.Reader       (MonadReader (local),
                                             ReaderT (runReaderT))
import           Control.Monad.State.Strict (MonadState, StateT, modify',
                                             runStateT)
import           Data.Foldable              (asum, foldl')
import qualified Data.Map                   as Map
import           Data.Map.Strict            (Map)
import           Data.Monoid                ((<>))
import qualified Data.Set                   as Set
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import           Data.Thyme                 (parseTime)
import           Data.Traversable           (for)
import           Data.Tuple                 (swap)
import           Data.Type.Equality         ((:~:) (Refl))
import           System.Locale              (defaultTimeLocale)

import           Pact.Types.Lang            (Info, Literal (..), PrimType (..),
                                             Type (..))
import qualified Pact.Types.Lang            as Pact
import qualified Pact.Types.Persistence     as Pact
import           Pact.Types.Typecheck       (AST, Named (Named), Node, aId,
                                             aNode, aTy, tiName, _aTy)
import qualified Pact.Types.Typecheck       as Pact
import           Pact.Types.Util            (tShow)

import           Pact.Analyze.Feature       hiding (TyVar, Var, obj, str, time)
import           Pact.Analyze.Patterns
import           Pact.Analyze.Types
import           Pact.Analyze.Util

-- * 'Text'/op prisms

mkOpNamePrism :: Ord op => [(Text, op)] -> Prism' Text op
mkOpNamePrism table =
  let mapForward = Map.fromList table
      lookupForward name = Map.lookup name mapForward

      mapReverse = Map.fromList (fmap swap table)
      lookupReverse op = mapReverse Map.! op
  in prism' lookupReverse lookupForward

toOp :: Prism' Text op -> Text -> Maybe op
toOp = preview

toText :: Prism' Text op -> op -> Text
toText = review

arithOpP :: Prism' Text ArithOp
arithOpP = mkOpNamePrism
  [ (SAddition,       Add)
  , (SSubtraction,    Sub)
  , (SMultiplication, Mul)
  , (SDivision,       Div)
  , (SExponentiation, Pow)
  , (SLogarithm,      Log)
  ]

unaryArithOpP :: Prism' Text UnaryArithOp
unaryArithOpP = mkOpNamePrism
  [ (SNumericNegation,  Negate)
  , (SSquareRoot,       Sqrt)
  , (SNaturalLogarithm, Ln)
  , (SExponential,      Exp)
  , (SAbsoluteValue,    Abs)
  -- explicitly no signum
  ]

comparisonOpP :: Prism' Text ComparisonOp
comparisonOpP = mkOpNamePrism
  [ (SGreaterThan,        Gt)
  , (SLessThan,           Lt)
  , (SGreaterThanOrEqual, Gte)
  , (SLessThanOrEqual,    Lte)
  , (SEquality,           Eq)
  , (SInequality,         Neq)
  ]

eqNeqP :: Prism' Text EqNeq
eqNeqP = mkOpNamePrism
  [ (SEquality,   Eq')
  , (SInequality, Neq')
  ]

roundingLikeOpP :: Prism' Text RoundingLikeOp
roundingLikeOpP = mkOpNamePrism
  [ (SBankersRound, Round)
  , (SCeilingRound, Ceiling)
  , (SFloorRound,   Floor)
  ]

logicalOpP :: Prism' Text LogicalOp
logicalOpP = mkOpNamePrism
  [ (SLogicalConjunction, AndOp)
  , (SLogicalDisjunction, OrOp)
  , (SLogicalNegation,    NotOp)
  ]

-- NOTE: we don't yet use symbols here because Feature (currently?) only
-- handles properties and invariants.
writeTypeP :: Prism' Text Pact.WriteType
writeTypeP = mkOpNamePrism
  [ ("insert", Pact.Insert)
  , ("update", Pact.Update)
  , ("write",  Pact.Write)
  ]

-- * Translation types

data TranslateFailure = TranslateFailure
  { _translateFailureInfo :: !Info
  , _translateFailure     :: !TranslateFailureNoLoc
  }

data TranslateFailureNoLoc
  = BranchesDifferentTypes EType EType
  | NonStringLitInBinding (AST Node)
  | EmptyBody
  | MalformedArithOp Text [AST Node]
  | MalformedLogicalOp Text [AST Node]
  | MalformedComparison Text [AST Node]
  | NotConvertibleToSchema (Pact.Type Pact.UserType)
  | TypeMismatch EType EType
  | UnexpectedNode (AST Node)
  | MissingConcreteType (Pact.Type Pact.UserType)
  | AlternativeFailures [TranslateFailureNoLoc]
  | MonadFailure String
  | NonStaticColumns (AST Node)
  | BadNegationType (AST Node)
  | BadTimeType (AST Node)
  | NonConstKey (AST Node)
  | FailedVarLookup Text
  -- For cases we don't handle yet:
  | UnhandledType (Pact.Type Pact.UserType)
  deriving (Eq, Show)

describeTranslateFailureNoLoc :: TranslateFailureNoLoc -> Text
describeTranslateFailureNoLoc = \case
  BranchesDifferentTypes t1 t2 -> "two branches unexpectedly have different types: (" <> tShow t1 <> ") vs (" <> tShow t2 <> ")"
  NonStringLitInBinding ast -> "We only support analysis of binding forms (bind / with-read) binding string literals. Instead we found " <> tShow ast
  EmptyBody -> "can't translate an empty body"
  MalformedArithOp op args -> "Unsupported arithmetic op " <> op <> " with args " <> tShow args
  MalformedLogicalOp op args -> "Unsupported logical op " <> op <> " with args " <> tShow args
  MalformedComparison op args -> "Unsupported comparison op " <> op <> " with args " <> tShow args
  NotConvertibleToSchema ty -> "Expected a schema, but found " <> tShow ty
  TypeMismatch ty1 ty2 -> "Type mismatch: (" <> tShow ty1 <> ") vs (" <> tShow ty2 <> ")"
  UnexpectedNode ast -> "Unexpected node in translation: " <> tShow ast
  MissingConcreteType ty -> "The typechecker should always produce a concrete type, but we found " <> tShow ty
  AlternativeFailures failures -> "Multiple failures: " <> T.unlines (mappend "  " . describeTranslateFailureNoLoc <$> failures)
  MonadFailure str -> "Translation failure: " <> T.pack str
  NonStaticColumns col -> "When reading only certain columns we require all columns to be concrete in order to do analysis. We found " <> tShow col
  BadNegationType node -> "Invalid: negation of a non-integer / decimal: " <> tShow node
  BadTimeType node -> "Invalid: days / hours / minutes applied to non-integer / decimal: " <> tShow node
  NonConstKey k -> "Pact can currently only analyze constant keys in objects. Found " <> tShow k
  FailedVarLookup varName -> "Failed to look up a variable (" <> varName <> "). This likely means the variable wasn't properly bound."
  UnhandledType ty -> "Found a type we don't know how to translate yet: " <> tShow ty

instance Monoid TranslateFailureNoLoc where
  mempty = AlternativeFailures []
  mappend (AlternativeFailures xs) (AlternativeFailures ys)
    = AlternativeFailures (xs `mappend` ys)
  mappend (AlternativeFailures xs) x = AlternativeFailures (x:xs)
  mappend x (AlternativeFailures xs) = AlternativeFailures (xs <> [x])
  mappend x y = AlternativeFailures [x, y]

instance Monoid TranslateFailure where
  mempty = TranslateFailure dummyInfo mempty
  TranslateFailure info1 x `mappend` TranslateFailure info2 y
    -- Note this instance is a bit odd, but `max` will find us a non-empty info
    -- if it exists (I think this is the only lawful way to do this).
    = TranslateFailure (max info1 info2) (x <> y)

mkTranslateEnv :: [Arg] -> Map Node (Text, VarId)
mkTranslateEnv = foldl'
  (\m (Arg nm vid node _ety) -> Map.insert node (nm, vid) m)
  Map.empty

data TranslateState
  = TranslateState
    { _tsTagAllocs :: [TagAllocation] -- "strict" WriterT isn't; so we use state
    , _tsNextTagId :: TagId
    , _tsNextVarId :: VarId
    }

makeLenses ''TranslateFailure
makeLenses ''TranslateState

instance HasVarId TranslateState where
  varId = tsNextVarId

newtype TranslateM a
  = TranslateM
    { unTranslateM :: ReaderT (Info, Map Node (Text, VarId))
                        (StateT TranslateState
                          (Except TranslateFailure))
                        a
    }
  deriving (Functor, Applicative, Monad, Alternative, MonadPlus,
    MonadReader (Info, Map Node (Text, VarId)), MonadState TranslateState,
    MonadError TranslateFailure)

instance MonadFail TranslateM where
  fail s = do
    info <- view _1
    throwError (TranslateFailure info (MonadFailure s))

-- * Translation

-- | Call when entering a node to set the current context
nodeContext :: Node -> TranslateM a -> TranslateM a
nodeContext node = local (_1 .~ nodeToInfo node)

-- | Call when entering an ast node to set the current context
astContext :: AST Node -> TranslateM a -> TranslateM a
astContext ast = local (_1 .~ astToInfo ast)

writeTagAlloc :: TagAllocation -> TranslateM ()
writeTagAlloc tagAlloc = modify' $ tsTagAllocs %~ cons tagAlloc

genTagId :: TranslateM TagId
genTagId = genId tsNextTagId

tagDbAccess
  :: (Located (TagId, Schema) -> TagAllocation)
  -> Node
  -> Schema
  -> TranslateM TagId
tagDbAccess mkTagAlloc node schema = do
  tid <- genTagId
  let info = node ^. aId . Pact.tiInfo
  writeTagAlloc $ mkTagAlloc $ Located info (tid, schema)
  pure tid

tagRead :: Node -> Schema -> TranslateM TagId
tagRead = tagDbAccess AllocReadTag

tagWrite :: Node -> Schema -> TranslateM TagId
tagWrite = tagDbAccess AllocWriteTag

tagAuth :: Node -> TranslateM TagId
tagAuth node = do
  tid <- genTagId
  let info = node ^. aId . Pact.tiInfo
  writeTagAlloc $ AllocAuthTag $ Located info tid
  pure tid

tagVarBinding :: Info -> Text -> EType -> VarId -> TranslateM ()
tagVarBinding info nm ety vid = writeTagAlloc $
  AllocVarTag (Located info (vid, nm, ety))

withNewVarId :: Node -> Text -> (VarId -> TranslateM a) -> TranslateM a
withNewVarId varNode varName action = do
  vid <- genVarId
  local (_2 . at varNode ?~ (varName, vid)) (action vid)

-- Map.union is left-biased. The more explicit name makes this extra clear.
unionPreferring :: Ord k => Map k v -> Map k v -> Map k v
unionPreferring = Map.union

maybeTranslateUserType :: Pact.UserType -> Maybe QType
maybeTranslateUserType (Pact.Schema _ _ fields _) =
  fmap (EObjectTy . Schema) $ sequence $ Map.fromList $ fields <&>
    \(Pact.Arg name ty _info) -> (name, maybeTranslateType ty)

maybeTranslateUserType' :: Pact.UserType -> Maybe EType
maybeTranslateUserType' = maybeTranslateUserType >=> downcastQType

maybeTranslateType :: Pact.Type Pact.UserType -> Maybe EType
maybeTranslateType
  = maybeTranslateType' maybeTranslateUserType >=> downcastQType

-- A helper to translate types that doesn't know how to handle user types
-- itself
maybeTranslateType'
  :: Alternative f
  => (a -> f QType)
  -> Pact.Type a
  -> f QType
maybeTranslateType' f = \case
  TyUser a         -> f a

  -- TODO(joel): understand the difference between the TyUser and TySchema cases
  TySchema Pact.TyTable _ -> pure QTable
  TySchema _ ty'   -> maybeTranslateType' f ty'

  TyPrim TyBool    -> pure $ EType TBool
  TyPrim TyDecimal -> pure $ EType TDecimal
  TyPrim TyInteger -> pure $ EType TInt
  TyPrim TyString  -> pure $ EType TStr
  TyPrim TyTime    -> pure $ EType TTime
  TyPrim TyKeySet  -> pure $ EType TKeySet

  -- Pretend any and an unknown var are the same -- we can't analyze either of
  -- them.
  -- TODO(joel): revisit this assumption
  TyVar (Pact.SchemaVar (Pact.TypeVarName "table")) -> pure QTable
  TyVar _                                           -> pure $ EType TAny
  TyAny                                             -> pure $ EType TAny

  --
  -- TODO: handle these:
  --
  TyPrim TyValue   -> empty
  TyList _         -> empty
  TyFun _          -> empty

throwError'
  :: (MonadError TranslateFailure m, MonadReader (Info, b) m)
  => TranslateFailureNoLoc -> m a
throwError' err = do
  info <- view _1
  throwError $ TranslateFailure info err

translateType
  :: (MonadError TranslateFailure m, MonadReader (Info, b) m)
  => Pact.Type Pact.UserType -> m EType
translateType = \case
  (maybeTranslateType -> Just ety) -> pure ety
  ty                               -> throwError' $ UnhandledType ty

translateArg
  :: (MonadState s m, HasVarId s, MonadError TranslateFailure m,
      MonadReader (Info, b) m)
  => Named Node
  -> m Arg
translateArg (Named nm node _) = do
  vid <- genVarId
  ety <- translateType (_aTy node)
  pure (Arg nm vid node ety)

translateSchema :: Pact.Type Pact.UserType -> TranslateM Schema
translateSchema ty = do
  ty' <- translateType ty
  case ty' of
    EType _primTy    -> throwError' $ NotConvertibleToSchema ty
    EObjectTy schema -> pure schema

translateBody :: [AST Node] -> TranslateM ETerm
translateBody = \case
  []       -> do
    info <- view _1
    throwError $ TranslateFailure info EmptyBody
  [ast]    -> translateNode ast
  ast:asts -> do
    ast'  <- translateNode ast
    asts' <- translateBody asts
    pure $ case asts' of
      ESimple ty astsT -> ESimple ty $ Sequence ast' astsT
      EObject ty astsO -> EObject ty $ Sequence ast' astsO

translateObjBinding
  :: [(Named Node, AST Node)]
  -> Schema
  -> [AST Node]
  -> ETerm
  -> TranslateM ETerm
translateObjBinding bindingsA schema bodyA rhsT = do
  (bindings :: [(String, EType, (Node, Text, VarId))]) <- for bindingsA $
    \(Named unmungedVarName varNode _, colAst) -> do
      let varName = varNode ^. aId.tiName
          varInfo = varNode ^. aId . Pact.tiInfo
      varType <- translateType (_aTy varNode)
      vid     <- genVarId
      tagVarBinding varInfo unmungedVarName varType vid
      case colAst of
        AST_StringLit colName ->
          pure (T.unpack colName, varType, (varNode, varName, vid))
        _ -> nodeContext varNode $ throwError' $ NonStringLitInBinding colAst

  bindingId <- genVarId
  let freshVar = PureTerm $ Var bindingId "binding"

  let translateLet :: Term a -> Term a
      translateLet innerBody = Let "binding" bindingId rhsT $
        -- NOTE: *left* fold for proper shadowing/overlapping name semantics:
        foldl'
          (\body (colName, varType, (_varNode, varName, vid)) ->
            let colTerm = lit colName
            in Let varName vid
              (case varType of
                 EType ty ->
                   ESimple ty  (PureTerm (At schema colTerm freshVar varType))
                 EObjectTy sch ->
                   EObject sch (PureTerm (At schema colTerm freshVar varType)))
              body)
          innerBody
          bindings

      nodeToNameVid = Map.fromList $
        (\(_, _, (node', name, vid)) -> (node', (name, vid))) <$> bindings

  fmap (mapExistential translateLet) $
    local (_2 %~ unionPreferring nodeToNameVid) $
      translateBody bodyA

translateNode :: AST Node -> TranslateM ETerm
translateNode astNode = astContext astNode $ case astNode of
  AST_Let _ [] body -> translateBody body

  AST_Let node ((Named unmungedVarName varNode _, rhsNode):bindingsRest) body -> do
    rhsETerm <- translateNode rhsNode
    let varName = varNode ^. aId.tiName
    withNewVarId varNode varName $ \vid -> do
      --
      -- TODO: do we only want to allow subsequent bindings to reference
      --       earlier ones if we know it's let* rather than let? or has this
      --       been enforced by earlier stages for us?
      --

      let varInfo = varNode ^. aId . Pact.tiInfo
          varType = existentialType rhsETerm

      tagVarBinding varInfo unmungedVarName varType vid

      body' <- translateNode $ AST_Let node bindingsRest body
      pure $ case body' of
        ESimple bodyTy bodyTm -> ESimple bodyTy (Let varName vid rhsETerm bodyTm)
        EObject bodyTy bodyTm -> EObject bodyTy (Let varName vid rhsETerm bodyTm)

  AST_InlinedApp body -> translateBody body

  AST_Var node -> do
    Just (varName, vid) <- view (_2 . at node)
    ty      <- translateType (_aTy node)
    pure $ case ty of
      EType ty'        -> ESimple ty'    $ PureTerm $ Var vid varName
      EObjectTy schema -> EObject schema $ PureTerm $ Var vid varName

  -- Int
  AST_NegativeLit l -> case l of
    LInteger i -> pure $ ESimple TInt (inject $ IntUnaryArithOp Negate (lit i))
    LDecimal d -> pure $ ESimple TDecimal (inject $ DecUnaryArithOp Negate (lit (mkDecimal d)))
    _          -> throwError' $ BadNegationType astNode

  AST_Lit l -> case l of
    LInteger i -> pure $ ESimple TInt (lit i)
    LBool b    -> pure $ ESimple TBool (lit b)
    LString s  -> pure $ ESimple TStr (lit $ T.unpack s)
    LDecimal d -> pure $ ESimple TDecimal (lit (mkDecimal d))
    LTime t    -> pure $ ESimple TTime (lit (mkTime t))

  AST_NegativeVar node -> do
    Just (name, vid) <- view (_2 . at node)
    EType ty <- translateType (_aTy node)
    case ty of
      TInt     -> pure $ ESimple TInt $ inject $ IntUnaryArithOp Negate $
        PureTerm $ Var vid name
      TDecimal -> pure $ ESimple TDecimal $ inject $ DecUnaryArithOp Negate $
        PureTerm $ Var vid name
      _        -> throwError' $ BadNegationType astNode

  AST_Enforce _ cond -> do
    ESimple TBool condTerm <- translateNode cond
    pure $ ESimple TBool $ Enforce condTerm

  AST_Format formatStr vars -> do
    ESimple TStr formatStr' <- translateNode formatStr
    vars' <- for vars translateNode
    pure $ ESimple TStr $ Format formatStr' vars'

  AST_FormatTime formatStr time -> do
    ESimple TStr formatStr' <- translateNode formatStr
    ESimple TTime time'     <- translateNode time
    pure $ ESimple TStr $ FormatTime formatStr' time'

  AST_ParseTime formatStr timeStr -> do
    ESimple TStr formatStr' <- translateNode formatStr
    ESimple TStr timeStr'   <- translateNode timeStr
    pure $ ESimple TTime $ ParseTime (Just formatStr') timeStr'

  AST_Time timeStr -> do
    ESimple TStr timeStr' <- translateNode timeStr
    pure $ ESimple TTime $ ParseTime Nothing timeStr'

  AST_Hash val -> do
    val' <- translateNode val
    pure $ ESimple TStr $ Hash val'

  AST_ReadKeyset nameA -> do
    ESimple TStr nameT <- translateNode nameA
    return $ ESimple TKeySet $ ReadKeySet nameT

  AST_EnforceKeyset ksA
    | ksA ^? aNode.aTy == Just (TyPrim TyString)
    -> do
      ESimple TStr ksnT <- translateNode ksA
      tid <- tagAuth $ ksA ^. aNode
      return $ ESimple TBool $ Enforce $ NameAuthorized tid ksnT

  AST_EnforceKeyset ksA
    | ksA ^? aNode.aTy == Just (TyPrim TyKeySet)
    -> do
      ESimple TKeySet ksT <- translateNode ksA
      tid <- tagAuth $ ksA ^. aNode
      return $ ESimple TBool $ Enforce (KsAuthorized tid ksT)

  AST_Days days -> do
    ESimple daysTy days' <- translateNode days
    case daysTy of
      TInt     -> pure $ ESimple TInt     $ inject $ IntArithOp Mul (60 * 60 * 24) days'
      TDecimal -> pure $ ESimple TDecimal $ inject $ DecArithOp Mul (60 * 60 * 24) days'
      _        -> throwError' $ BadTimeType astNode

  AST_Hours hours -> do
    ESimple hoursTy hours' <- translateNode hours
    case hoursTy of
      TInt     -> pure $ ESimple TInt     $ inject $ IntArithOp Mul (60 * 60) hours'
      TDecimal -> pure $ ESimple TDecimal $ inject $ DecArithOp Mul (60 * 60) hours'
      _        -> throwError' $ BadTimeType astNode

  AST_Minutes minutes -> do
    ESimple minutesTy minutes' <- translateNode minutes
    case minutesTy of
      TInt     -> pure $ ESimple TInt     $ inject $ IntArithOp Mul 60 minutes'
      TDecimal -> pure $ ESimple TDecimal $ inject $ DecArithOp Mul 60 minutes'
      _        -> throwError' $ BadTimeType astNode

  AST_NFun _node "time" [AST_Lit (LString timeLit)]
    | Just timeLit'
      <- parseTime defaultTimeLocale Pact.simpleISO8601 (T.unpack timeLit)
    -> pure $ ESimple TTime $ lit (mkTime timeLit')

  AST_NFun_Basic fn args ->
    let throwMalformedComp :: forall a. TranslateM a
        throwMalformedComp = throwError' $ MalformedComparison fn args

        mkComparison :: TranslateM ETerm
        mkComparison =
          case args of
            [a, b] -> do
              ESimple ta a' <- translateNode a
              ESimple tb b' <- translateNode b
              op <- maybe throwMalformedComp pure $ toOp comparisonOpP fn
              case (ta, tb) of
                (TInt, TInt) -> pure $
                  ESimple TBool $ PureTerm $ IntegerComparison op a' b'
                (TDecimal, TDecimal) -> pure $
                  ESimple TBool $ PureTerm $ DecimalComparison op a' b'
                (TTime, TTime) -> pure $
                  ESimple TBool $ PureTerm $ TimeComparison op a' b'
                (TStr, TStr) -> pure $
                  ESimple TBool $ PureTerm $ StringComparison op a' b'
                (TBool, TBool) -> pure $
                  ESimple TBool $ PureTerm $ BoolComparison op a' b'
                (_, _) -> case typeEq ta tb of
                  Just Refl -> throwMalformedComp
                  _         -> throwError' $ TypeMismatch (EType ta) (EType tb)
            _ -> throwMalformedComp

        mkKeySetEqNeq :: TranslateM ETerm
        mkKeySetEqNeq = case args of
          [a, b] -> do
            ESimple TKeySet a' <- translateNode a
            ESimple TKeySet b' <- translateNode b
            op <- maybe throwMalformedComp pure $ toOp eqNeqP fn
            pure $ ESimple TBool $ PureTerm $ KeySetEqNeq op a' b'
          _ -> throwMalformedComp

        mkObjEqNeq :: TranslateM ETerm
        mkObjEqNeq = case args of
          [a, b] -> do
            EObject _ a' <- translateNode a
            EObject _ b' <- translateNode b
            op <- maybe throwMalformedComp pure $ toOp eqNeqP fn
            pure $ ESimple TBool $ PureTerm $ ObjectEqNeq op a' b'
          _ -> throwMalformedComp

        mkLogical :: TranslateM ETerm
        mkLogical = do
          let throwMalformed :: forall a. TranslateM a
              throwMalformed = throwError' $ MalformedLogicalOp fn args

          terms <- traverse translateNode args
          op <- maybe throwMalformed pure $ toOp logicalOpP fn
          case (op, terms) of
            (NotOp, [ESimple TBool a]) -> pure $
              ESimple TBool $ PureTerm $ Logical op [a]
            (_, [ESimple TBool a, ESimple TBool b]) -> pure $
              ESimple TBool $ PureTerm $ Logical op [a, b]
            _ -> throwMalformed

        mkArith :: TranslateM ETerm
        mkArith = do
          let throwMalformed :: forall a. TranslateM a
              throwMalformed = throwError' $ MalformedArithOp fn args

              mArithOp = toOp arithOpP fn
              mRoundOp = toOp roundingLikeOpP fn
              mUnaryOp = toOp unaryArithOpP fn

          terms <- traverse translateNode args

          case terms of
            [ESimple tyA a, ESimple tyB b] ->
              case fmap Left mArithOp <|> fmap Right mRoundOp of
                Nothing -> throwMalformed
                Just (Left op) ->
                  case (tyA, tyB) of
                    (TInt, TInt) -> pure $
                      ESimple TInt $ inject $ IntArithOp op a b
                    (TDecimal, TDecimal) -> pure $
                      ESimple TDecimal $ inject $ DecArithOp op a b
                    (TInt, TDecimal) -> pure $
                      ESimple TDecimal $ inject $ IntDecArithOp op a b
                    (TDecimal, TInt) -> pure $
                      ESimple TDecimal $ inject $ DecIntArithOp op a b
                    _ -> throwMalformed
                Just (Right op) ->
                  case (tyA, tyB, op) of
                    (TDecimal, TInt, Round) -> pure $
                      ESimple TDecimal $ inject $ RoundingLikeOp2 op a b
                    (TDecimal, TInt, Ceiling) -> pure $
                      ESimple TDecimal $ inject $ RoundingLikeOp2 op a b
                    (TDecimal, TInt, Floor) -> pure $
                      ESimple TDecimal $ inject $ RoundingLikeOp2 op a b
                    _ -> throwMalformed
            [ESimple tyA a] ->
              case fmap Left mUnaryOp <|> fmap Right mRoundOp of
                Nothing -> throwMalformed
                Just (Left op) ->
                  case tyA of
                    TInt -> pure $
                      ESimple TInt $ inject $ IntUnaryArithOp op a
                    TDecimal -> pure $
                      ESimple TDecimal $ inject $ DecUnaryArithOp op a
                    _ -> throwMalformed
                Just (Right op) ->
                  case tyA of
                    TDecimal ->
                      pure $ ESimple TInt $ inject $ RoundingLikeOp1 op a
                    _ -> throwMalformed
            _ -> throwMalformed

        mkConcat :: TranslateM ETerm
        mkConcat = case (fn, args) of
          (SStringConcatenation, [a, b]) -> do
            ESimple TStr a' <- translateNode a
            ESimple TStr b' <- translateNode b
            pure $ ESimple TStr $ PureTerm $ StrConcat a' b'
          _ -> mzero

        mkObjMerge :: TranslateM ETerm
        mkObjMerge = case (fn, args) of
          (SObjectMerge, [a, b]) -> do
            EObject s1 o1 <- translateNode a
            EObject s2 o2 <- translateNode b
            pure $ EObject (s1 <> s2) $ PureTerm $ ObjectMerge o1 o2
          _ -> mzero

        mkMod :: TranslateM ETerm
        mkMod = case (fn, args) of
          (SModulus, [a, b]) -> do
            ESimple TInt a' <- translateNode a
            ESimple TInt b' <- translateNode b
            pure $ ESimple TInt $ inject $ ModOp a' b'
          _ -> mzero

    in asum [mkMod, mkArith, mkComparison, mkKeySetEqNeq, mkObjEqNeq,
         mkLogical, mkConcat, mkObjMerge]

  AST_NFun node (toOp writeTypeP -> Just writeType) [ShortTableName tn, row, obj] -> do
    ESimple TStr row'   <- translateNode row
    EObject schema obj' <- translateNode obj
    tid                 <- tagWrite node schema
    pure $ ESimple TStr $
      Write writeType tid (TableName (T.unpack tn)) schema row' obj'

  AST_If _ cond tBranch fBranch -> do
    ESimple TBool cond' <- translateNode cond
    ESimple ta a        <- translateNode tBranch
    ESimple tb b        <- translateNode fBranch
    case typeEq ta tb of
      Just Refl -> pure $ ESimple ta $ IfThenElse cond' a b
      _         -> throwError' (BranchesDifferentTypes (EType ta) (EType tb))

  AST_NFun _node "pact-version" [] -> pure $ ESimple TStr PactVersion

  AST_WithRead node table key bindings schemaNode body -> do
    schema            <- translateSchema (_aTy schemaNode)
    ESimple TStr key' <- translateNode key
    tid               <- tagRead node schema
    let readT = EObject schema $ Read tid (TableName (T.unpack table)) schema key'
    nodeContext node $
      translateObjBinding bindings schema body readT

  AST_Bind node objectA bindings schemaNode body -> do
    schema  <- translateSchema (_aTy schemaNode)
    objectT <- translateNode objectA
    nodeContext node $
      translateObjBinding bindings schema body objectT

  AST_AddTime time seconds
    | seconds ^. aNode . aTy == TyPrim TyInteger ||
      seconds ^. aNode . aTy == TyPrim TyDecimal -> do
      ESimple TTime time' <- translateNode time
      ESimple ty seconds' <- translateNode seconds

      case ty of
        TInt ->
          pure $ ESimple TTime $ PureTerm $ IntAddTime time' seconds'
        TDecimal ->
          pure $ ESimple TTime $ PureTerm $ DecAddTime time' seconds'
        _ -> throwError' $ MonadFailure $
          "Unexpected type for seconds in add-time " ++ show ty

  AST_Read node table key -> do
    ESimple TStr key' <- translateNode key
    schema <- translateSchema (_aTy node)
    tid <- tagRead node schema
    pure $ EObject schema $ Read tid (TableName (T.unpack table)) schema key'

  -- Note: this won't match if the columns are not a list literal
  AST_ReadCols node table key columns -> do
    ESimple TStr key' <- translateNode key
    (Schema fields) <- translateSchema (_aTy node)
    columns' <- fmap Set.fromList $ for columns $ \case
      AST_Lit (LString col) -> pure col
      bad                   -> throwError' (NonStaticColumns bad)
    let schema = Schema $
          Map.filterWithKey (\k _ -> k `Set.member` columns') fields

    tid <- tagRead node schema
    pure $ EObject schema $
      Read tid (TableName (T.unpack table)) schema key'

  AST_At node colName obj -> do
    EObject schema obj'   <- translateNode obj
    ESimple TStr colName' <- translateNode colName
    ty <- translateType (_aTy node)
    pure $ case ty of
      EType ty'         -> ESimple ty'     $ PureTerm $ At schema colName' obj' ty
      EObjectTy schema' -> EObject schema' $ PureTerm $ At schema colName' obj' ty

  AST_Obj node kvs -> do
    kvs' <- for kvs $ \(k, v) -> do
      k' <- case k of
        AST_Lit (LString t) -> pure t
        -- TODO: support non-const keys
        _                   -> throwError' $ NonConstKey k
      v' <- translateNode v
      pure (k', v')
    schema <- translateSchema (_aTy node)
    pure $ EObject schema $ PureTerm $ LiteralObject $ Map.fromList kvs'

  ast -> throwError' $ UnexpectedNode ast

runTranslation
  :: Info
  -> [Named Node]
  -> [AST Node]
  -> Except TranslateFailure ([Arg], ETerm, [TagAllocation])
runTranslation info pactArgs body = do
    (args, translationVid) <- runArgsTranslation
    (tm, tagAllocs) <- runBodyTranslation args translationVid
    pure (args, tm, tagAllocs)

  where
    runArgsTranslation :: Except TranslateFailure ([Arg], VarId)
    runArgsTranslation =
      -- Note we add () as a second value in the reader context because some
      -- methods require a reader in a pair.
      runStateT
        (runReaderT (traverse translateArg pactArgs) (info, ()))
        (VarId 1)

    runBodyTranslation
      :: [Arg] -> VarId -> Except TranslateFailure (ETerm, [TagAllocation])
    runBodyTranslation args nextVarId = fmap (fmap _tsTagAllocs) $
      flip runStateT (TranslateState [] 0 nextVarId) $
        runReaderT
          (unTranslateM (translateBody body))
          (info, mkTranslateEnv args)
