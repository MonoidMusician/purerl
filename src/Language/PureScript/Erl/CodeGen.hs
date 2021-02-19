{-# LANGUAGE GADTs #-}

-- |
-- This module generates code in the simplified Erlang intermediate representation from Purescript code
--
module Language.PureScript.Erl.CodeGen
  ( module AST
  , moduleToErl
  ) where

import Prelude.Compat

import Language.PureScript.Erl.CodeGen.AST as AST

import qualified Data.Text as T
import Data.Traversable ( forM )
import Data.Foldable ( find, traverse_ )
import Data.List (nub)
import Control.Monad (unless, replicateM, (<=<))

import qualified Data.Set as Set
import Data.Set (Set)

import qualified Data.Map as M
import Data.Map (Map)
import Data.Maybe (fromMaybe, mapMaybe, catMaybes)
import Control.Monad.Error.Class (MonadError(..))
import Control.Monad.Error
import Control.Applicative ((<|>))
import Control.Arrow (first, second)
import Control.Monad.Reader (MonadReader(..))
import Control.Monad.Writer (MonadWriter(..))

import Control.Monad.Supply.Class

import Language.PureScript.CoreFn hiding (moduleExports)
import Language.PureScript.Errors (ErrorMessageHint(..))
import Language.PureScript.Options ( Options )
import Language.PureScript.Names
    ( runIdent,
      showIdent,
      showQualified,
      Ident(UnusedIdent, Ident),
      ModuleName(..),
      ProperName(ProperName),
      Qualified(..) )
import Language.PureScript.Types
    ( SourceType,
      Type(TypeVar, RCons, REmpty, TypeLevelString, TypeConstructor,
           ConstrainedType, ForAll, TypeApp) )
import Language.PureScript.Label ( Label(runLabel) )
import Language.PureScript.Environment as E
    ( Environment(names, types, typeSynonyms),
      tyArray,
      tyBoolean,
      tyFunction,
      tyInt,
      tyNumber,
      tyRecord,
      tyString )
import qualified Language.PureScript.Constants as C
import Language.PureScript.Traversals (sndM)
import Language.PureScript.AST (SourceSpan, nullSourceSpan, nullSourceAnn)

import Language.PureScript.Erl.Errors.Types
    ( SimpleErrorMessage(UnusedFFIImplementations,
                         MissingFFIImplementations, InvalidFFIArity) )
import Language.PureScript.Erl.Errors (MultipleErrors, rethrow, rethrowWithPosition, addHint, errorMessage)
import Language.PureScript.Erl.CodeGen.Common
    ( ModuleType(ForeignModule, PureScriptModule),
      runAtom,
      atomPS,
      atomModuleName,
      toAtomName,
      identToVar,
      toVarName,
      erlModuleNameBase )
import Language.PureScript.Erl.Synonyms (replaceAllTypeSynonymsM)
import Debug.Trace (traceM, trace, traceShowM, traceShow, traceShowId)
import qualified Language.PureScript as P
import qualified Language.PureScript.TypeChecker as T
import Control.Monad.State (State, put, modify, gets, runState, evalStateT, MonadState(..), StateT)


freshNameErl :: (MonadSupply m) => m T.Text
freshNameErl = fmap (("_@" <>) . T.pack . show) fresh

identToTypeclassCtor :: Ident -> Atom
identToTypeclassCtor a = Atom Nothing (runIdent a)

qualifiedToTypeclassCtor :: Qualified Ident -> Atom
qualifiedToTypeclassCtor (Qualified (Just mn) ident) = Atom (Just $ atomModuleName mn PureScriptModule) (runIdent ident)
qualifiedToTypeclassCtor (Qualified  Nothing ident) = Atom Nothing (runIdent ident)

isTopLevelBinding :: Qualified t -> Bool
isTopLevelBinding (Qualified (Just _) _) = True
isTopLevelBinding (Qualified Nothing _) = False

tyArity :: SourceType -> Int
tyArity (TypeApp _ (TypeApp _ fn _) ty) | fn == E.tyFunction = 1 + tyArity ty
tyArity (ForAll _ _ _ ty _) = tyArity ty
tyArity (ConstrainedType _ _ ty) = 1 + tyArity ty
tyArity _ = 0

collectTypeApp :: SourceType -> Maybe (Qualified (ProperName 'P.TypeName), [SourceType])
collectTypeApp = go []
  where
    go acc (TypeConstructor _ tc) = Just (tc, acc)
    go acc (TypeApp _ t1 t2) = go (t2:acc) t1
    go acc (ForAll _ _ _ ty _) = go acc ty
    go _ _ = Nothing

uncurriedFnTypes :: ModuleName -> T.Text -> SourceType -> Maybe (Int,[SourceType])
uncurriedFnTypes moduleName fnName = check <=< collectTypeApp 
  where
    check :: (Qualified (ProperName 'P.TypeName), [SourceType]) -> Maybe (Int,[SourceType])
    check (Qualified (Just mn) (ProperName fnN), tys)  =
      let n = length tys - 1
      in
      if n >= 1 && n <= 10 && fnN == (fnName <> T.pack (show n)) && mn == moduleName
      then Just (n, tys)
      else Nothing

uncurriedFnArity :: ModuleName -> T.Text -> SourceType -> Maybe Int
uncurriedFnArity moduleName fnName ty = fst <$> uncurriedFnTypes moduleName fnName ty

effect :: ModuleName
effect = ModuleName "Effect"

effectUncurried :: ModuleName
effectUncurried = ModuleName "Effect.Uncurried"

dataFunctionUncurried :: ModuleName
dataFunctionUncurried = ModuleName "Data.Function.Uncurried"

erlDataList :: ModuleName
erlDataList = ModuleName "Erl.Data.List"

erlDataMap :: ModuleName
erlDataMap = ModuleName "Erl.Data.Map"

type ETypeEnv = Map T.Text ([T.Text], EType)

-- |
-- Generate code in the simplified Erlang intermediate representation for all declarations in a
-- module.
--
moduleToErl :: forall m .
    (Monad m, MonadReader Options m, MonadSupply m, MonadError MultipleErrors m, MonadWriter MultipleErrors m)
  => E.Environment
  -> Module Ann
  -> [(T.Text, Int)]
  -> m ([T.Text], [Erl], [Erl], [Erl])
moduleToErl env (Module _ _ mn _ _ declaredExports foreigns decls) foreignExports =

  -- translateType (TypeConstructor _ tname) | Just res <- M.lookup tname (E.names env)  = 
  --   traceShow res TAny

  rethrow (addHint (ErrorInModule mn)) $ do
    
    -- traceShowM $ M.filterWithKey (\(Qualified  mn' _) _ -> mn' == Just (ModuleName "Test")) (E.types env)

    res <- traverse topBindToErl decls
    reexports <- traverse reExportForeign foreigns
    let exportTypes = mapMaybe (\(_,_,t) -> t) reexports
        typeEnv = M.unions $ map (snd . snd) exportTypes
        foreignSpecs = map (\(ident, (ty, _)) -> ESpec (qualifiedToErl' mn ForeignModule ident) (replaceVars ty)) exportTypes
        
        (exports, erlDecls, typeEnv') = concatRes $ res <> map (\(a,b,c) -> (a, b, maybe M.empty (snd . snd) c)) reexports
        namedSpecs = map (\(name, (args, ty)) -> EType (Atom Nothing name) args ty) $ M.toList $ M.union typeEnv typeEnv'
     
    traverse_ checkExport foreigns
    let usedFfi = Set.fromList $ map runIdent foreigns
        definedFfi = Set.fromList (map fst foreignExports)
        unusedFfi = definedFfi Set.\\ usedFfi
    unless (Set.null unusedFfi) $
      tell $ errorMessage $ UnusedFFIImplementations mn (Ident <$> Set.toAscList unusedFfi)

    let attributes = findAttributes decls

    return (map (\(a,i) -> runAtom a <> "/" <> T.pack (show i)) exports, namedSpecs, foreignSpecs, attributes ++ erlDecls)
  where



  types :: M.Map (Qualified Ident) SourceType
  types = M.map (\(t, _, _) -> t) $ E.names env

  declaredExportsSet :: Set Ident
  declaredExportsSet = Set.fromList declaredExports

  findAttributes :: [Bind Ann] -> [Erl]
  findAttributes expr = map (uncurry EAttribute) $ mapMaybe getAttribute $ concatMap onBind expr
    where
      getAttribute (TypeApp _ (TypeApp _ (TypeConstructor _ (Qualified (Just _) (ProperName "Attribute"))) (TypeLevelString _ a)) (TypeLevelString _ b))
        = Just (a,b)
      getAttribute _ = Nothing

      getType ident =  M.lookup (Qualified (Just mn) ident) types

      onRecBind ((_, ident), _) = getType ident
      onBind (NonRec _ ident _) = catMaybes [ getType ident ]
      onBind (Rec vals) = mapMaybe onRecBind vals

  concatRes :: [([a], [b], ETypeEnv)] -> ([a], [b], ETypeEnv)
  concatRes x = (concatMap (\(a,_,_) -> a) x, concatMap (\(_, b, _) -> b) x, M.unions $ (\(_,_,c) -> c) <$> x)

  explicitArities :: M.Map (Qualified Ident) Int
  explicitArities = tyArity <$> types

  arities :: M.Map (Qualified Ident) Int
  arities =
    -- max arities is max of actual impl and most saturated application
    let actualArities = M.fromList $ map (\(x, n) -> (Qualified (Just mn) (Ident x), n)) foreignExports
        inferredMaxArities = foldr findApps actualArities decls
    in explicitArities `M.union` inferredMaxArities

  -- 're-export' foreign imports in the @ps module - also used for internal calls for non-exported foreign imports
  reExportForeign :: Ident -> m ([(Atom,Int)], [Erl], Maybe (Ident, (EType, ETypeEnv)))
  reExportForeign ident = do

    let arity = exportArity ident
        fullArity = fromMaybe arity (M.lookup (Qualified (Just mn) ident) arities)
        wrap (ty, tenv) = case arity of 
                            0 -> Just (TFun [] ty, tenv)
                            _ -> (, tenv) <$> uncurryType arity ty
    ty :: Maybe (EType, ETypeEnv) <- 
      case M.lookup (Qualified (Just mn) ident) types of
        Just t -> do
          t' <- replaceAllTypeSynonymsM (typeSynonyms env) t
          
          pure $ traceShow t $if t == t' then 
              wrap (translateType t')
              else
              traceShow (t, t') $
                wrap (translateType t')
        Nothing -> pure Nothing

    args <- replicateM fullArity freshNameErl
    let body = EApp (EAtomLiteral $ qualifiedToErl' mn ForeignModule ident) (take arity $ map EVar args)
        body' = curriedApp (drop arity $ map EVar args) body
        fun = curriedLambda body' args
    fident <- fmap (Ident . ("f" <>) . T.pack . show) fresh
    let var = Qualified Nothing fident
        wrap e = EBlock [ EVarBind (identToVar fident) fun, e ]
    (idents, erl, _env) <- generateFunctionOverloads Nothing (ssAnn nullSourceSpan) ident (Atom Nothing $ runIdent ident) (Var (ssAnn nullSourceSpan) var) wrap
    pure (idents, erl, (ident,) <$> ty)

  curriedLambda :: Erl -> [T.Text] -> Erl
  curriedLambda = foldr (EFun1 Nothing)

  exportArity :: Ident -> Int
  exportArity ident = fromMaybe 0 $ findExport $ runIdent ident

  checkExport :: Ident -> m ()
  checkExport ident =
    case (findExport (runIdent ident), M.lookup (Qualified (Just mn) ident) explicitArities) of
      -- TODO is it meaningful to check against inferred arities (as we are just now) or only explicit ones
      -- This probably depends on the current codegen

      -- If we know the foreign import type (because it was exported) and the actual FFI type, it is an error if
      -- the actual implementation has higher arity than the type does
      -- If the actual implementation has lower arity, it may be just returning a function
      (Just m, Just n) | m > n ->
        throwError . errorMessage $ InvalidFFIArity mn (runIdent ident) m n

      -- If we don't know the declared type of the foreign import (because it is not exported), then we cannot say
      -- what the implementation's arity should be, as it may be higher than can be inferred from applications in this
      -- module (because there is no fully saturated application) or lower (because the ffi returns a function)
      (Just _, Nothing) ->
          pure ()

      -- We certainly can tell if an import exists and the implementation isn't found
      -- The opposite situation is handled at the top level of moduleToErl
      (Nothing, _) ->
        throwError . errorMessage $ MissingFFIImplementations mn [ident]
      _ -> pure ()

  findExport :: T.Text -> Maybe Int
  findExport n = snd <$> find ((n==) . fst) foreignExports

  topBindToErl :: Bind Ann -> m ([(Atom,Int)], [Erl],ETypeEnv)
  topBindToErl (NonRec ann ident val) = topNonRecToErl ann ident val
  topBindToErl (Rec vals) = concatRes <$> traverse (uncurry . uncurry $ topNonRecToErl) vals

  uncurriedFnArity' :: ModuleName -> T.Text -> Qualified Ident -> Maybe Int
  uncurriedFnArity' fnMod fn ident =
    case M.lookup ident types of
      Just t -> uncurriedFnArity fnMod fn t
      _ -> Nothing

  effFnArity = uncurriedFnArity' effectUncurried "EffectFn"
  fnArity = uncurriedFnArity' dataFunctionUncurried "Fn"

  topNonRecToErl :: Ann -> Ident -> Expr Ann -> m ([(Atom,Int)], [ Erl ], ETypeEnv)
  topNonRecToErl (ss, _, _, _) ident val = do
    let eann@(_, _, _, meta') = extractAnn val
        ident' = case meta' of
          Just IsTypeClassConstructor -> identToTypeclassCtor ident
          _ -> Atom Nothing $ runIdent ident


    generateFunctionOverloads (Just ss) eann ident ident' val id

  generateFunctionOverloads :: Maybe SourceSpan -> Ann -> Ident -> Atom -> Expr Ann -> (Erl -> Erl)  -> m ([(Atom,Int)], [ Erl ], ETypeEnv)
  generateFunctionOverloads ss eann ident ident' val outerWrapper = do
    -- Always generate the plain curried form, f x y = ... -~~> f() -> fun (X) -> fun (Y) -> ... end end.
    let qident = Qualified (Just mn) ident
    erl <- valueToErl val

    
    let translated = translateType <$> M.lookup qident types
        erlangType = replaceVars <$> fst <$> translated
        etypeEnv = maybe M.empty snd translated
    
    let curried = ( [ (ident', 0) ], [ EFunctionDef (TFun [] <$> erlangType) ss ident' [] (outerWrapper erl) ] )
    -- For effective > 0 (either plain curried funs, FnX or EffectFnX) generate an uncurried overload
    -- f x y = ... -~~> f(X,Y) -> ((...)(X))(Y).
    -- Relying on inlining to clean up some junk here
    let mkRunApp modName prefix n = App eann (Var eann (Qualified (Just modName) (Ident $ prefix <> T.pack (show n))))
        (wrap, unwrap) = case effFnArity qident of
          Just n -> (mkRunApp effectUncurried C.runEffectFn n, \e -> EApp e [])
          _ | Just n <- fnArity qident -> (mkRunApp dataFunctionUncurried C.runFn n, id)
          _ -> (id, id)


    uncurried <- case effFnArity qident <|> fnArity qident <|> M.lookup qident arities of
      Just arity | arity > 0 -> do
        vars <- replicateM arity freshNameErl
        -- Apply in CoreFn then translate to take advantage of translation of full/partial application
        erl' <- valueToErl $ foldl (\fn a -> App eann fn (Var eann (Qualified Nothing (Ident a)))) (wrap val) vars
        pure ( [ (ident', arity) ], [ EFunctionDef (uncurryType arity =<< erlangType) ss ident' vars (outerWrapper (unwrap erl')) ] )
      _ -> pure ([], [])

    let (res1, res2) = curried <> uncurried
    pure $ if ident `Set.member` declaredExportsSet
            then (res1, res2, etypeEnv)
            else ([], res2, etypeEnv)

  -- substitute any() for any var X, for use in specs
  replaceVars :: EType -> EType
  replaceVars = go
    where
    go = \case
      TVar _ -> TAny
      TFun args res -> TFun (go <$> args) (go res)
      TList arg -> TList $ go arg
      TMap (Just args) -> TMap $ Just $ map (\(a,b) -> (go a, go b)) args
      TTuple args -> TTuple $ go <$> args
      TUnion args -> TUnion $ go <$> args
      TRemote a b args -> TRemote a b $ go <$> args
      TAlias x args -> TAlias x $ go <$> args
      z -> z

  translateType :: SourceType -> (EType, ETypeEnv)
  translateType = flip runState M.empty . go 
    where
    go :: SourceType -> State (ETypeEnv) EType
    go = \case
      (TypeApp _ (TypeApp _ fn t1) t2) | fn == E.tyFunction ->
          TFun <$> sequence [ go t1 ] <*> go t2
      ty | ty == E.tyInt -> pure TInteger
      ty | ty == E.tyNumber -> pure TFloat
      ty | ty == E.tyString -> pure $ TAlias (Atom Nothing "binary") []
      ty | ty == E.tyBoolean -> pure $ TAlias (Atom Nothing "boolean") []
      (TypeApp _ t1 t2) | t1 == E.tyArray ->
        TRemote "array" "array" . pure <$> go t2
      (TypeApp _ t1 t2) | t1 == ctorTy erlDataList "List" ->
        TList <$> go t2
      (TypeApp _ (TypeApp _ t t1) t2) | t == ctorTy erlDataMap "Map" -> do
        rT1 <- go t1
        rT2 <- go t2
        pure $ TMap $ Just [(rT1, rT2)]
      (TypeApp _ t1 t2) | t1 == ctorTy effect "Effect" ->
        TFun [] <$> go t2
      (TypeApp _ tr t1) | tr == tyRecord ->
        TMap <$> row t1 []
          where
            row (REmpty _) acc = pure $ Just acc
            row (RCons _ label t ttail) acc = do
              tt <- go t
              row ttail ((TAtom $ Just $ AtomPS Nothing $ runLabel label, tt) : acc)
            row (TypeVar _ _) _ = pure Nothing
            row t _ = 
              trace ("Shouldn't find random type in row list: " <> show t) $ pure Nothing
                -- 

      (ForAll _ _ _ ty _) -> go ty
      (ConstrainedType _ _ ty) -> TFun [ TAny ] <$> go ty


      ty
        | Just (_, fnTypes) <- uncurriedFnTypes dataFunctionUncurried "Fn" ty
        , tret <- last fnTypes
        , targs <- take (length fnTypes -1 ) fnTypes
        -> TFun <$> (traverse go targs) <*> (go tret)
      ty
        | Just (_, fnTypes) <- uncurriedFnTypes effectUncurried "EffectFn" ty
        , tret <- last fnTypes
        , targs <- take (length fnTypes -1 ) fnTypes
        -> TFun <$> (traverse go targs) <*> (go tret)
            
      t@(TypeApp _ _ _) 
        | Just (tname, tys) <- collectTypeApp t 
        -> do
          etys <- traverse go tys
          -- traceShowM ("collected application", tname, etys, M.lookup tname (E.typeSynonyms env), M.lookup tname (E.types env))
          res <- goTCtor etys tname
          -- traceShowM ("and done for", tname)
          pure res

      (TypeVar _ var) -> pure $ TVar $ "_" <> toVarName var

      _ -> pure TAny
 
    erlTypeName :: (Qualified (ProperName 'P.TypeName)) -> T.Text
    erlTypeName (Qualified mn' ident)
      | Just mn'' <- mn' =
      -- TODO this is easier to read but clashes builtins
      -- , mn'' /= mn = 
          toAtomName $ erlModuleNameBase mn'' <> "_" <> P.runProperName ident
      | otherwise =
        toAtomName $ P.runProperName ident

    goTCtor :: [EType] -> (Qualified (ProperName 'P.TypeName)) -> State (ETypeEnv) EType
    goTCtor tyargs = \case
      tname
        | Just (args, t) <- M.lookup tname (E.typeSynonyms env)
        , length args == length tyargs
        , (Qualified _mn ident) <- tname -> do
        let erlName = erlTypeName tname
        M.lookup erlName <$> get >>= \case
          Just _ -> 
            pure ()
          Nothing -> do
            -- dummy to prevent recursing
            modify (M.insert erlName (map (("_" <>) . toVarName . fst) args, TAny))
            tt <- go t
            modify (M.insert erlName (map (("_" <>) . toVarName . fst) args, tt))
        pure $ TAlias (Atom Nothing erlName) tyargs

      tname
        | Just (_, t) <- M.lookup tname (E.types env)
        --  DataType [(Text, Maybe SourceKind)] [(ProperName 'ConstructorName, [SourceType])]
        , P.DataType dtargs (ctors :: [(ProperName 'P.ConstructorName, [SourceType])]) <- t
        , length dtargs == length tyargs
        -- can't ignore mn for external stuff
        , (Qualified mn' ident) <- tname
        -> do
          let erlName = erlTypeName tname
          M.lookup erlName <$> get >>= \case
            Just _ -> pure ()
            Nothing -> do
              -- dummy to prevent recursing
              modify (M.insert erlName (map (("_" <>) . toVarName . fst) dtargs, TAny))
              let alt (ctorName, ctorArgs) = do
                                    targs <- traverse go ctorArgs
                                    pure $ case isNewtypeConstructor env (Qualified mn' ctorName) of
                                        Just True -> head targs
                                        Just False -> TTuple (TAtom (Just $ Atom Nothing $ toAtomName $ P.runProperName ctorName): targs)
                                        Nothing -> 
                                          -- TODO if we put this in the defining module maybe an opaque type would be useful to prevent some misuse
                                          TAny
              tt <- traverse alt ctors
              let union = case length tt of 
                            0 -> TAny -- arguably none()
                            _ -> TUnion tt
              modify (M.insert erlName (map (("_" <>)  .toVarName . fst) dtargs, union))

          pure $ TAlias (Atom Nothing erlName) tyargs
      -- not a data type/alias we can find or not fully applied
      tname -> pure TAny

  lookupConstructor :: Environment -> Qualified (P.ProperName 'P.ConstructorName) -> Maybe (P.DataDeclType, ProperName 'P.TypeName, P.SourceType, [Ident])
  lookupConstructor env ctor =
    ctor `M.lookup` P.dataConstructors env

  -- | Checks whether a data constructor is for a newtype.
  isNewtypeConstructor :: Environment -> Qualified (P.ProperName 'P.ConstructorName) -> Maybe Bool
  isNewtypeConstructor e ctor = case lookupConstructor e ctor of
    Just (P.Newtype, _, _, _) -> Just True
    Just (P.Data, _, _, _) -> Just False
    Nothing -> Nothing

  ctorTy :: ModuleName -> T.Text -> SourceType
  ctorTy modName fn = TypeConstructor nullSourceAnn (Qualified (Just modName) (ProperName fn))

  uncurryType :: Int -> EType -> Maybe EType
  uncurryType arity = uc []
    where
      uc [] uncurriedType@(TFun ts _) | length ts > 1 = Just uncurriedType
      uc ts (TFun [ t1 ] t2) = uc (t1:ts) t2
      uc ts t | length ts == arity = Just $ TFun (reverse ts) t
      uc _ _ = Nothing



  findApps :: Bind Ann -> M.Map (Qualified Ident) Int -> M.Map (Qualified Ident) Int
  findApps (NonRec _ _ val) apps = findApps' val apps
  findApps (Rec vals) apps = foldr findApps' apps $ map snd vals

  findApps' :: Expr Ann -> M.Map (Qualified Ident) Int -> M.Map (Qualified Ident) Int
  findApps' expr apps = case expr of
    e@App{} ->
      let (f, args) = unApp e []
          apps' = foldr findApps' apps args
      in
      case f of
        Var (_, _, _, Just IsNewtype) _ -> apps'
        Var (_, _, _, Just (IsConstructor _ fields)) (Qualified _ _) | length args == length fields ->
          apps'
        Var (_, _, _, Just IsTypeClassConstructor) _ ->
          apps'
        Var _ qi@(Qualified (Just mn') _) | mn' == mn
          -> M.alter (updateArity $ length args) qi apps'
        _ -> findApps' f apps'
    Accessor _ _ e -> findApps' e apps
    ObjectUpdate _ e es -> findApps' e $ foldr findApps' apps $ map snd es
    Abs _ _ e -> findApps' e apps
    Case _ e es -> foldr findApps' (foldr findAppsCase apps es) e
    Let _ b e' ->
      findApps' e' $ foldr findApps'' apps b
    _ -> apps
    where
      updateArity newArity old@(Just oldArity) | oldArity > newArity = old
      updateArity newArity _ = Just newArity

      unApp :: Expr Ann -> [Expr Ann] -> (Expr Ann, [Expr Ann])
      unApp (App _ val arg) args = unApp val (arg : args)
      unApp other args = (other, args)

  findApps'' (NonRec _ _ e) apps = findApps' e apps
  findApps'' (Rec binds) apps = foldr findApps' apps $ map snd binds


  findAppsCase (CaseAlternative _ (Right e)) apps = findApps' e apps
  findAppsCase (CaseAlternative _ (Left ges)) apps = foldr findApps' apps $ map snd ges


  bindToErl :: Bind Ann -> m [Erl]
  bindToErl (NonRec _ ident val) =
    pure . EVarBind (identToVar ident) <$> valueToErl' (Just ident) val

  -- For recursive bindings F(X) = E1, G(X) = E2, ... we have a problem as the variables are not
  -- in scope until each expression is defined. To avoid lifting to the top level first generate
  -- funs which take a tuple of such funs F'({F', G'}) -> (X) -> E1 etc.
  -- with occurences of F, G replaced in E1, E2 with F'({F',G'})
  -- and then bind these F = F'({F',G'})
  -- TODO: Only do this if there are multiple mutually recursive bindings! Else a named fun works.
  bindToErl (Rec vals) = do
    let vars = identToVar . snd . fst <$> vals
        varTup = ETupleLiteral $ EVar . (<> "@f") <$> vars
        replaceFun fvar = everywhereOnErl go
          where
            go (EVar f) | f == fvar = EApp (EVar $ f <> "@f") [varTup]
            go e = e

    funs <- forM vals $ \((_, ident), val) -> do
      erl <- valueToErl' Nothing val
      let erl' = foldr replaceFun erl vars
      let fun = EFunFull Nothing [(EFunBinder [varTup] Nothing, erl')]
      pure $ EVarBind (identToVar ident <> "@f") fun
    let rebinds = map (\var -> EVarBind var (EApp (EVar $ var <> "@f") [varTup])) vars
    pure $ funs ++ rebinds

  qualifiedToErl' mn' moduleType ident = Atom (Just $ atomModuleName mn' moduleType) (runIdent ident)

  -- Top level definitions are everywhere fully qualified, variables are not.
  qualifiedToErl (Qualified (Just mn') ident) | mn == mn' && ident `Set.notMember` declaredExportsSet  =
    Atom Nothing (runIdent ident) -- Local reference to local non-exported function
  qualifiedToErl (Qualified (Just mn') ident) = qualifiedToErl' mn' PureScriptModule ident -- Reference other modules or exported things via module name
  qualifiedToErl x = error $ "Invalid qualified identifier " <> T.unpack (showQualified showIdent x)

  qualifiedToVar (Qualified _ ident) = identToVar ident

  valueToErl :: Expr Ann -> m Erl
  valueToErl = valueToErl' Nothing

  valueToErl' :: Maybe Ident -> Expr Ann -> m Erl
  valueToErl' _ (Literal (pos, _, _, _) l) =
    rethrowWithPosition pos $ literalToValueErl l
  valueToErl' _ (Var _ (Qualified (Just C.Prim) (Ident undef))) | undef == C.undefined =
    return $ EAtomLiteral $ Atom Nothing C.undefined
  valueToErl' _ (Var _ ident) | isTopLevelBinding ident = pure $
    case M.lookup ident arities of
      Just 1 -> EFunRef (qualifiedToErl ident) 1
      _ | Just arity <- effFnArity ident <|> fnArity ident
        , arity > 0 -> EFunRef (qualifiedToErl ident) arity
      _ -> EApp (EAtomLiteral $ qualifiedToErl ident) []

  valueToErl' _ (Var _ ident) = return $ EVar $ qualifiedToVar ident

  valueToErl' ident (Abs _ arg val) = do
    ret <- valueToErl val

    -- TODO this is mangled in corefn json
    let fixIdent (Ident "$__unused") = UnusedIdent
        fixIdent x = x
        arg' = case fixIdent arg of
                  UnusedIdent -> "_"
                  _           -> identToVar arg
    return $ EFun1 (fmap identToVar ident) arg' ret

  valueToErl' _ (Accessor _ prop val) = do
    eval <- valueToErl val
    return $ EApp (EAtomLiteral $ Atom (Just "maps") "get") [EAtomLiteral $ AtomPS Nothing prop, eval]

  valueToErl' _ (ObjectUpdate _ o ps) = do
    obj <- valueToErl o
    sts <- mapM (sndM valueToErl) ps
    return $ EMapUpdate obj (map (first (AtomPS Nothing)) sts)

  valueToErl' _ e@App{} = do
    let (f, args) = unApp e []
    args' <- mapM valueToErl args
    case f of
      Var (_, _, st, Just IsNewtype) _ -> 
        return $ head args'
      Var (_, _, _, Just (IsConstructor _ fields)) (Qualified _ ident) | length args == length fields ->
        return $ constructorLiteral (runIdent ident) args'
      Var (_, _, _, Just IsTypeClassConstructor) name ->
        return $ curriedApp args' $ EApp (EAtomLiteral $ qualifiedToTypeclassCtor name) []

      Var _ qi@(Qualified _ _)
        | arity <- fromMaybe 0 (M.lookup qi arities)
        , length args == arity
        -> return $ EApp (EAtomLiteral (qualifiedToErl qi)) args'

      _ -> curriedApp args' <$> valueToErl f
    where
    unApp :: Expr Ann -> [Expr Ann] -> (Expr Ann, [Expr Ann])
    unApp (App _ val arg) args = unApp val (arg : args)
    unApp other args = (other, args)

  valueToErl' _ (Case _ values binders) = do
    vals <- mapM valueToErl values
    (exprs, binders', newvals) <- bindersToErl vals binders
    let ret = EApp (EFunFull Nothing binders') (vals++newvals)
    pure $ case exprs of
      [] -> ret
      _ -> EBlock (exprs ++ [ret])
  valueToErl' _ (Let _ ds val) = do
    ds' <- concat <$> mapM bindToErl ds
    ret <- valueToErl val
    -- TODO: Rename variables rather than creating temporary scope just for this
    -- TODO: This scope doesn't really work probably if we actually want to shadow parent scope (avoiding siblings is fine)
    return $ iife (ds' ++ [ret])

  valueToErl' _ (Constructor (_, _, _, Just IsNewtype) _ _ _) = error "newtype ctor"
  valueToErl' _ (Constructor _ _ (ProperName ctor) fields) =
    let createFn =
          let body = constructorLiteral ctor ((EVar . identToVar) `map` fields)
          in foldr (\f inner -> EFun1 Nothing (identToVar f) inner) body fields
    in pure createFn

  iife exprs = EApp (EFun0 Nothing (EBlock exprs)) []

  constructorLiteral name args = ETupleLiteral (EAtomLiteral (Atom Nothing (toAtomName name)) : args)

  curriedApp :: [Erl] -> Erl -> Erl
  curriedApp = flip (foldl (\fn a -> EApp fn [a]))

  literalToValueErl :: Literal (Expr Ann) -> m Erl
  literalToValueErl = literalToValueErl' EMapLiteral valueToErl

  literalToValueErl' ::  ([(Atom,Erl)] -> Erl) -> (a -> m Erl) -> Literal a -> m Erl
  literalToValueErl' _ _ (NumericLiteral n) = return $ ENumericLiteral n
  literalToValueErl' _ _ (StringLiteral s) = return $ EStringLiteral s
  literalToValueErl' _ _ (CharLiteral c) = return $ ECharLiteral c
  literalToValueErl' _ _ (BooleanLiteral b) = return $ boolToAtom b
  literalToValueErl' _ f (ArrayLiteral xs) = do
    array <- EArrayLiteral <$> mapM f xs
    pure $ EApp (EAtomLiteral $ Atom (Just "array") "from_list") [array]
  literalToValueErl' mapLiteral f (ObjectLiteral ps) = do
    pairs <- mapM (sndM f) ps
    pure $ mapLiteral $ map (first (AtomPS Nothing)) pairs

  boolToAtom :: Bool -> Erl
  boolToAtom True = EAtomLiteral $ Atom Nothing "true"
  boolToAtom False = EAtomLiteral $ Atom Nothing "false"

  bindersToErl :: [Erl] -> [CaseAlternative Ann] -> m ([Erl], [(EFunBinder, Erl)], [Erl])
  bindersToErl vals cases = do
    let binderLengths = map (length . caseAlternativeBinders) $ cases
        maxBinders = maximum binderLengths
    if (length (nub binderLengths) > 1) then
      traceM $ "Found inconsistent binder lengths: " <> show binderLengths
    else
      pure ()
    res <- mapM (caseToErl maxBinders) cases
    let arrayVars = map fst $ concatMap (\(_,_,x) -> x) res
        convBinder (count, binds) (_, binders, arrayMatches) =
          (count + length arrayMatches, binds ++ map go binders)
          where
            go (EFunBinder bs z, e) = (EFunBinder (bs++padBinds count arrayMatches) z, e)
        padBinds n binds = replicate n (EVar "_") ++ (map snd binds) ++ replicate (length arrayVars - n - length binds) (EVar "_")
        binders' = snd $ foldl convBinder (0, []) res

    pure (concatMap (\(x,_,_) -> x) res, binders', arrayVars)
    where
    caseToErl :: Int -> CaseAlternative Ann -> m ([Erl], [(EFunBinder, Erl)], [(Erl, Erl)])
    caseToErl numBinders (CaseAlternative binders alt) = do
      let binders' = binders ++ (replicate (numBinders - length binders) $ NullBinder (nullSourceSpan , [], Nothing, Nothing))
      b' <- mapM (binderToErl' vals) binders'
      let (bs, erls) = second concat $ unzip b'
      (es, res) <- case alt of
        Right e -> do
          e' <- valueToErl e
          pure ([], [(EFunBinder bs Nothing, e')])
        Left guards -> first concat . unzip <$> mapM (guard bs) guards
      pure (es ++ map ((\f -> f (EFunBinder bs Nothing)) . fst) erls, res, map (first EVar . snd) erls)
    guard bs (ge, e) = do
      var <- freshNameErl
      ge' <- valueToErl ge
      let binder = EFunBinder bs Nothing
          fun = EFunFull Nothing
                  ((binder, ge') :
                  if irrefutable binder then []
                  else [(EFunBinder (replicate (length bs) (EVar "_")) Nothing, boolToAtom False)])
          cas = EApp fun vals
      e' <- valueToErl e
      pure ([EVarBind var cas], (EFunBinder bs (Just $ Guard $ EVar var), e'))

  binderToErl' :: [Erl] -> Binder Ann -> m (Erl,[(EFunBinder -> Erl,(T.Text, Erl))])
  binderToErl' _ (NullBinder _) = pure (EVar "_", [])
  binderToErl' _ (VarBinder _ ident) = pure (EVar $ identToVar ident, [])
  binderToErl' vals (LiteralBinder _ (ArrayLiteral es)) = do
    x <- freshNameErl
    args' <- mapM (binderToErl' vals) es

    let cas binder = EApp (EFunFull Nothing
                ((binder, EApp (EAtomLiteral $ Atom (Just "array") "to_list") [EVar x]) :
                  if irrefutable binder then []
                  else [(EFunBinder (replicate (length vals) (EVar "_")) Nothing, EAtomLiteral $ Atom Nothing "nil")]))
                vals
    var <- freshNameErl

    let arr = EArrayLiteral (map fst args')
    pure (EVar x, ((EVarBind var . cas, (var, arr)) : concatMap snd args'))
  binderToErl' vals (LiteralBinder _ lit) = (,[]) <$> literalToValueErl' EMapPattern (fmap fst . binderToErl' vals) lit
  binderToErl' vals (ConstructorBinder (_, _, _, Just IsNewtype) _ _ [b]) = binderToErl' vals b
  binderToErl' vals (ConstructorBinder _ _ (Qualified _ (ProperName ctorName)) binders) = do
    args' <- mapM (binderToErl' vals) binders
    pure (constructorLiteral ctorName (map fst args'), concatMap snd args')
  binderToErl' vals (NamedBinder _ ident binder) = do
    (e, xs) <- binderToErl' vals binder
    pure (EVarBind (identToVar ident) e, xs)

  irrefutable (EFunBinder bindEs Nothing) = all isVar bindEs
    where isVar (EVar _) = True
          isVar _ = False
  irrefutable _ = False

