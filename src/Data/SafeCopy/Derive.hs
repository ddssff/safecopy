{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

module Data.SafeCopy.Derive
  ( deriveSafeCopy
  , deriveSafeCopy'
  , deriveSafeCopySimple
  , deriveSafeCopySimple'
  , deriveSafeCopyHappstackData
  , deriveSafeCopyHappstackData'
  , deriveSafeCopyIndexedType
  , deriveSafeCopyIndexedType'
  , deriveSafeCopySimpleIndexedType
  , deriveSafeCopySimpleIndexedType'
  , deriveSafeCopyHappstackDataIndexedType
  , deriveSafeCopyHappstackDataIndexedType'
  , renderTH
  , renderDecs
  ) where

-- import Data.Generics.Labels ()
import Data.Serialize (getWord8, putWord8, label)
import Data.SafeCopy.SafeCopy (Version(unVersion), SafeCopy(version, kind, errorTypeName, getCopy, putCopy), contain, getSafePut, getSafeGet, safeGet, safePut)
import Language.Haskell.TH hiding (Kind)
import Control.Lens ((%=), _1, _3, makeLenses, over, set, to, use, view)
import Control.Monad
import Control.Monad.Trans.Class as MTL (lift)
import Control.Monad.Trans.RWS.Lazy as MTL (ask, execRWST, local, RWST, tell)
-- import Data.Data (Data)
import Data.Generics (Data, everywhere, mkT)
import Data.List (intercalate, intersperse, isPrefixOf, nub)
import Data.Maybe (fromMaybe)
import Data.String (IsString(fromString))
#ifdef __HADDOCK__
import Data.Word (Word8) -- Haddock
#endif
import Debug.Trace
import GHC.Generics (Generic)
import GHC.Stack (callStack, getCallStack, HasCallStack, SrcLoc(..))
import Language.Haskell.TH.PprLib (Doc, to_HPJ_Doc)
import Language.Haskell.TH.Syntax
-- import SeeReason.SrcLoc (compactStack)
import qualified Text.PrettyPrint as HPJ

data DeriveType = Normal | Simple | HappstackData

data R a =
  R { _deriveType :: DeriveType
    , _versionId :: Version a
    , _kindName :: Name
    , _freeVars :: [Name]
    , _params :: [Type]
    -- , _bindings :: [(Name, Type)]
    , _indent :: String }

type W = [Dec]

data S =
  S { _extraContext :: Cxt
    , _bindings :: [(Name, Type)]
    }

$(makeLenses ''R)
$(makeLenses ''S)

-- | Derive an instance of 'SafeCopy'.
--
--   When serializing, we put a 'Word8' describing the
--   constructor (if the data type has more than one
--   constructor).  For each type used in the constructor, we
--   call 'getSafePut' (which immediately serializes the version
--   of the type).  Then, for each field in the constructor, we
--   use one of the put functions obtained in the last step.
--
--   For example, given the data type and the declaration below
--
--   @
--data T0 b = T0 b Int
--deriveSafeCopy 1 'base ''T0
--   @
--
--   we generate
--
--   @
--instance (SafeCopy a, SafeCopy b) =>
--         SafeCopy (T0 b) where
--    putCopy (T0 arg1 arg2) = contain $ do put_b   <- getSafePut
--                                          put_Int <- getSafePut
--                                          put_b   arg1
--                                          put_Int arg2
--                                          return ()
--    getCopy = contain $ do get_b   <- getSafeGet
--                           get_Int <- getSafeGet
--                           return T0 \<*\> get_b \<*\> get_Int
--    version = 1
--    kind = base
--   @
--
--   And, should we create another data type as a newer version of @T0@, such as
--
--   @
--data T a b = C a a | D b Int
--deriveSafeCopy 2 'extension ''T
--
--instance SafeCopy b => Migrate (T a b) where
--  type MigrateFrom (T a b) = T0 b
--  migrate (T0 b i) = D b i
--   @
--
--   we generate
--
--   @
--instance (SafeCopy a, SafeCopy b) =>
--         SafeCopy (T a b) where
--    putCopy (C arg1 arg2) = contain $ do putWord8 0
--                                         put_a <- getSafePut
--                                         put_a arg1
--                                         put_a arg2
--                                         return ()
--    putCopy (D arg1 arg2) = contain $ do putWord8 1
--                                         put_b   <- getSafePut
--                                         put_Int <- getSafePut
--                                         put_b   arg1
--                                         put_Int arg2
--                                         return ()
--    getCopy = contain $ do tag <- getWord8
--                           case tag of
--                             0 -> do get_a <- getSafeGet
--                                     return C \<*\> get_a \<*\> get_a
--                             1 -> do get_b   <- getSafeGet
--                                     get_Int <- getSafeGet
--                                     return D \<*\> get_b \<*\> get_Int
--                             _ -> fail $ \"Could not identify tag \\\"\" ++
--                                         show tag ++ \"\\\" for type Main.T \" ++
--                                         \"that has only 2 constructors.  \" ++
--                                         \"Maybe your data is corrupted?\"
--    version = 2
--    kind = extension
--   @
--
--   Note that by using getSafePut, we saved 4 bytes in the case
--   of the @C@ constructor.  For @D@ and @T0@, we didn't save
--   anything.  The instance derived by this function always use
--   at most the same space as those generated by
--   'deriveSafeCopySimple', but never more (as we don't call
--   'getSafePut'/'getSafeGet' for types that aren't needed).
--
--   Note that you may use 'deriveSafeCopySimple' with one
--   version of your data type and 'deriveSafeCopy' in another
--   version without any problems.
deriveSafeCopy :: Version a -> Name -> Name -> Q [Dec]
deriveSafeCopy versionId kindName tyName = do
  deriveSafeCopy' versionId kindName (conT tyName)

-- | Generalized version of 'deriveSafeCopy', takes a 'Type' rather
-- than a type 'Name'.
deriveSafeCopy' :: Version a -> Name -> TypeQ -> Q [Dec]
deriveSafeCopy' versionId kindName typ = do
  internalDeriveSafeCopy Normal versionId kindName typ

-- | Derive an instance of 'SafeCopy'.  The instance derived by
--   this function is simpler than the one derived by
--   'deriveSafeCopy' in that we always use 'safePut' and
--   'safeGet' (instead of 'getSafePut' and 'getSafeGet').
--
--   When serializing, we put a 'Word8' describing the
--   constructor (if the data type has more than one constructor)
--   and, for each field of the constructor, we use 'safePut'.
--
--   For example, given the data type and the declaration below
--
--   @
--data T a b = C a a | D b Int
--deriveSafeCopySimple 1 'base ''T
--   @
--
--   we generate
--
--   @
--instance (SafeCopy a, SafeCopy b) =>
--         SafeCopy (T a b) where
--    putCopy (C arg1 arg2) = contain $ do putWord8 0
--                                         safePut arg1
--                                         safePut arg2
--                                         return ()
--    putCopy (D arg1 arg2) = contain $ do putWord8 1
--                                         safePut arg1
--                                         safePut arg2
--                                         return ()
--    getCopy = contain $ do tag <- getWord8
--                           case tag of
--                             0 -> do return C \<*\> safeGet \<*\> safeGet
--                             1 -> do return D \<*\> safeGet \<*\> safeGet
--                             _ -> fail $ \"Could not identify tag \\\"\" ++
--                                         show tag ++ \"\\\" for type Main.T \" ++
--                                         \"that has only 2 constructors.  \" ++
--                                         \"Maybe your data is corrupted?\"
--    version = 1
--    kind = base
--   @
--
--   Using this simpler instance means that you may spend more
--   bytes when serializing data.  On the other hand, it is more
--   straightforward and may match any other format you used in
--   the past.
--
--   Note that you may use 'deriveSafeCopy' with one version of
--   your data type and 'deriveSafeCopySimple' in another version
--   without any problems.
deriveSafeCopySimple :: Version a -> Name -> Name -> Q [Dec]
deriveSafeCopySimple versionId kindName tyName =
  deriveSafeCopySimple' versionId kindName (conT tyName)

deriveSafeCopySimple' :: Version a -> Name -> TypeQ -> Q [Dec]
deriveSafeCopySimple' versionId kindName typ = do
  internalDeriveSafeCopy Simple versionId kindName typ

-- | Derive an instance of 'SafeCopy'.  The instance derived by
--   this function should be compatible with the instance derived
--   by the module @Happstack.Data.SerializeTH@ of the
--   @happstack-data@ package.  The instances use only 'safePut'
--   and 'safeGet' (as do the instances created by
--   'deriveSafeCopySimple'), but we also always write a 'Word8'
--   tag, even if the data type isn't a sum type.
--
--   For example, given the data type and the declaration below
--
--   @
--data T0 b = T0 b Int
--deriveSafeCopy 1 'base ''T0
--   @
--
--   we generate
--
--   @
--instance (SafeCopy a, SafeCopy b) =>
--         SafeCopy (T0 b) where
--    putCopy (T0 arg1 arg2) = contain $ do putWord8 0
--                                          safePut arg1
--                                          safePut arg2
--                                          return ()
--    getCopy = contain $ do tag <- getWord8
--                           case tag of
--                             0 -> do return T0 \<*\> safeGet \<*\> safeGet
--                             _ -> fail $ \"Could not identify tag \\\"\" ++
--                                         show tag ++ \"\\\" for type Main.T0 \" ++
--                                         \"that has only 1 constructors.  \" ++
--                                         \"Maybe your data is corrupted?\"
--    version = 1
--    kind = base
--   @
--
--   This instance always consumes at least the same space as
--   'deriveSafeCopy' or 'deriveSafeCopySimple', but may use more
--   because of the useless tag.  So we recomend using it only if
--   you really need to read a previous version in this format,
--   and not for newer versions.
--
--   Note that you may use 'deriveSafeCopy' with one version of
--   your data type and 'deriveSafeCopyHappstackData' in another version
--   without any problems.
deriveSafeCopyHappstackData :: Version a -> Name -> Name -> Q [Dec]
deriveSafeCopyHappstackData versionId kindName tyName =
  deriveSafeCopyHappstackData' versionId kindName (conT tyName)

deriveSafeCopyHappstackData' :: Version a -> Name -> TypeQ -> Q [Dec]
deriveSafeCopyHappstackData' versionId kindName typq = do
  internalDeriveSafeCopy HappstackData versionId kindName typq

-- * Type traversal.

-- | Traverse a types to collect information about what context the
-- 'SafeCopy' instance will need, and then output a declaration of the
-- 'SafeCopy' instance.
internalDeriveSafeCopy :: HasCallStack => DeriveType -> Version a -> Name -> TypeQ -> Q [Dec]
internalDeriveSafeCopy deriveType versionId kindName typq = do
  (S _ bindings, decs) <-
    execRWST (doType =<< MTL.lift typq)
      (R deriveType versionId kindName [] [] "") (S mempty [])
  let decs' = everywhere (mkT (expand bindings)) decs
  pure ({-trace ("decs=" <> vis decs' <> "\nbindings=" <> show bindings)-} decs')

doType :: HasCallStack => Type -> RWST (R a) W S Q ()
doType typ = -- traceLocM ("doType " <> ren typ) $
  case typ of
    ConT tyName -> doTypeName tyName
    ForallT tyvars cxt' typ' -> do
      extraContext %= (<> cxt')
      local (over freeVars (fmap unKind tyvars <>)) $ doType typ'
    AppT t1 t2 -> local (over params (t2 :)) $ doType t1
    TupleT n -> doTypeName (tupleTypeName n)
    _ -> fail $ "Can't derive SafeCopy instance for: " ++ show typ -- ++ " (" <> compactStack getStack <> ")"

doTypeName :: Name -> RWST (R a) W S Q ()
doTypeName tyName = -- traceLocM ("doTypeName " <> ren tyName) $
  MTL.lift (reify tyName) >>= doInfo tyName

-- | Process the info obtained from a type name
doInfo :: HasCallStack => Name -> Info -> RWST (R a) W S Q ()
doInfo tyName info = -- traceLocM ("doInfo " <> ren tyName <> " (" <> ren info <> ")") $
  case info of
    TyConI (DataD context _name tyvars _kind cons _derivs)
      | length cons > 255 -> fail $ "Can't derive SafeCopy instance for: " ++ show tyName ++
                                    ". The datatype must have less than 256 constructors."
      | otherwise -> do
          extraContext %= (++ ({-traceLoc ("context=" <> ren context)-} context))
          withBindings tyvars $ do
            doCons tyName (ConT tyName) tyvars cons

    TyConI (NewtypeD context _name tyvars _kind con _derivs) -> do
      extraContext %= (<> context)
      withBindings tyvars $ do
        doCons tyName (ConT tyName) tyvars [con]

    FamilyI _ insts -> do
      mapM_ (doInst tyName info . instCompat) insts
    _ -> fail $ "Can't derive SafeCopy instance for: " ++ show (tyName, info) -- ++ " (" <> compactStack getStack <> ")"

withBindings :: [TyVarBndr] -> RWST (R a) W S Q () -> RWST (R a) W S Q ()
withBindings tyvars action = do
  ps <- view params
  case length ps <= length tyvars of
    False -> fail $ "Arity error"
    True -> do
      let (tobind, remaining) = splitAt (length tyvars) ps
      let newbindings :: [(Name, Type)]
          newbindings = zip (fmap unKind tyvars) tobind
      bindings %= (newbindings <>)
      local (set params remaining) $ action

unKind :: TyVarBndr -> Name
unKind (PlainTV name) = name
unKind (KindedTV name _) = name

doInst :: HasCallStack => Name -> Info -> Maybe (Cxt, Type, Maybe Kind, [Con], [DerivClause]) -> RWST (R a) W S Q ()
doInst _ info Nothing = fail $ "Can't derive SafeCopy instance for: " ++ show info
doInst tyName _ (Just (context, nty, _knd, cons, _derivs)) = do
  extraContext %= (<> context)
  doCons tyName nty [] cons

doCons :: HasCallStack => Name -> Type -> [TyVarBndr] -> [Con] -> RWST (R a) W S Q ()
doCons tyName tyBase tyvars cons = do
  let ty = foldl AppT tyBase (fmap (\var -> VarT $ tyVarName var) tyvars)
  mapM_ doCon cons
  context <- use extraContext
  r <- ask
  dec <- MTL.lift $
    instanceD
      (cxt (fmap pure (nub context)))
      (pure (ConT ''SafeCopy `AppT` ty))
      [ mkPutCopy (_deriveType r) (zip [0..] cons)
      , mkGetCopy (_deriveType r) (renderTH (ppr . everywhere (mkT cleanName)) (ConT tyName)) (zip [0..] cons)
      , valD (varP 'version) (normalB $ litE $ integerL $ fromIntegral $ unVersion (_versionId r)) []
      , valD (varP 'kind) (normalB (varE (_kindName r))) []
      , funD 'errorTypeName [clause [wildP] (normalB $ litE $ StringL (renderTH (ppr . everywhere (mkT cleanName)) (ConT tyName))) []] ]
  tell [dec]

doCon :: HasCallStack => Con -> RWST (R a) W S Q ()
doCon con = -- traceLocM ("doCon " <> ren con) $ do
  withSubs con $ \case
    NormalC _name types -> mapM_ doField (fmap snd types)
    RecC _name types -> mapM_ doField (fmap (view _3) types)
    InfixC type1 _name type2 -> doField (snd type1) >> doField (snd type2)
    ForallC _tyvars context con' -> do
      extraContext %= (<> ({-traceLoc ("context=" <> show context)-} context))
      doCon con'
    GadtC _names _types _typ -> pure ()
    RecGadtC _name _types _typ -> pure ()

withSubs :: Data t => t -> (t -> RWST (R a) W S Q ()) -> RWST (R a) W S Q ()
withSubs a f = do
  bnd <- use bindings
  f (everywhere (mkT (expand bnd)) a)

expand :: [(Name, Type)] -> Type -> Type
expand bindings typ@(VarT name) =
  case lookup name bindings of
    Nothing -> typ
    Just typ' -> {-trace ("sub: " <> show typ <> " -> " <> show typ')-} typ'
expand _ typ = typ

-- | Values which appear in the fields of the type, these need
-- instances if they are polymorphic.
doField :: HasCallStack => Type -> RWST (R a) W S Q ()
doField typ = -- traceLocM ("doField " <> vis typ) $
  case polymorphic typ of
    False -> pure ()
    True -> do
      context <- MTL.lift [t|SafeCopy $(pure typ)|]
      extraContext %= (<> [context])

-- | If we don't encounter any type variables when traversing the type
-- it is considered to be fixed, not polymorphic.  In that case we
-- assume the required instance is already visible, so no context is
-- needed.  If the instance is an orphan it might not be visible, so
-- this would fail.
polymorphic :: Type -> Bool
polymorphic (ConT _tyName) = False
polymorphic (VarT _tyName) = True
polymorphic (ForallT _ _ typ) = polymorphic typ
polymorphic (AppT typ param) = polymorphic param || polymorphic typ
polymorphic ListT = False
polymorphic (TupleT _) = False
polymorphic typ = error ("polymorphic " <> (show typ))

instCompat :: Dec -> Maybe (Cxt, Type, Maybe Kind, [Con], [DerivClause])
#if MIN_VERSION_template_haskell(2,15,0)
instCompat (DataInstD context name nty knd cons derivs) =
  Just (context, nty, knd, cons, derivs)
instCompat (NewtypeInstD context name nty knd con derivs) =
  Just (context, nty, knd, [con], derivs)
#else
instCompat (DataInstD context name ty knd cons derivs) =
  Just (context, foldl AppT (ConT name) ty, knd, cons, derivs)
instCompat (NewtypeInstD context name ty knd con derivs) =
  Just (context, foldl AppT (ConT name) ty, knd, [con], derivs)
#endif
instCompat _inst = Nothing

-- | Apply the TH pretty printer to a value after stripping any added
-- suffixes from its names.  This may make it uncompilable, but it
-- eliminates a source of randomness in the expected and actual test
-- case results.
renderTH :: {-Data a =>-} (a -> Doc) -> a -> String
renderTH pretty decs =
  HPJ.renderStyle (HPJ.style {HPJ.lineLength = 1000000 {-HPJ.mode = HPJ.OneLineMode-}}) $
  to_HPJ_Doc $
  pretty $
  decs

renderDecs :: [Dec] -> String
renderDecs = renderTH (ppr . everywhere (mkT briefName))

-- | Names with the best chance of compiling when prettyprinted:
--    * Remove all package and module names
--    * Remove suffixes on all constructor names
--    * Remove suffixes on the four ids we export
--    * Leave suffixes on all variables and type variables
cleanName :: Name -> Name
cleanName (Name oc (NameG _ns _pn mn)) = Name oc (NameQ mn)
cleanName (Name oc (NameQ mn)) = Name oc (NameQ mn)
cleanName (Name oc@(OccName _) (NameU _)) = Name oc NameS
cleanName name@(Name _ (NameL _)) = name -- Not seeing any of these
cleanName name@(Name _ NameS) = name

#if MIN_VERSION_template_haskell(2,17,0)
tyVarName :: TyVarBndr s -> Name
tyVarName (PlainTV n _) = n
tyVarName (KindedTV n _ _) = n
#else
tyVarName :: TyVarBndr -> Name
tyVarName (PlainTV n) = n
tyVarName (KindedTV n _) = n
#endif

-- * Build the methods of the SafeCopy instance.

mkPutCopy :: DeriveType -> [(Integer, Con)] -> DecQ
mkPutCopy deriveType cons = funD 'putCopy $ map mkPutClause cons
    where
      manyConstructors = length cons > 1 || forceTag deriveType
      mkPutClause (conNumber, con)
          = do putVars <- mapM (\n -> newName ("a" ++ show n)) [1..conSize con]
               (putFunsDecs, putFuns) <- case deriveType of
                                           Normal -> mkSafeFunctions "safePut_" 'getSafePut con
                                           _      -> return ([], const 'safePut)
               let putClause   = conP (conName con) (map varP putVars)
                   putCopyBody = varE 'contain `appE` doE (
                                   [ noBindS $ varE 'putWord8 `appE` litE (IntegerL conNumber) | manyConstructors ] ++
                                   putFunsDecs ++
                                   [ noBindS $ varE (putFuns typ) `appE` varE var | (typ, var) <- zip (conTypes con) putVars ] ++
                                   [ noBindS $ varE 'return `appE` tupE [] ])
               clause [putClause] (normalB putCopyBody) []

mkGetCopy :: DeriveType -> String -> [(Integer, Con)] -> DecQ
mkGetCopy deriveType tyName cons = valD (varP 'getCopy) (normalB $ varE 'contain `appE` mkLabel) []
    where
      mkLabel = varE 'label `appE` litE (stringL (tyName ++ ":")) `appE` getCopyBody
      getCopyBody
          = case cons of
              [(_, con)] | not (forceTag deriveType) -> mkGetBody con
              _ -> do
                tagVar <- newName "tag"
                doE [ bindS (varP tagVar) (varE 'getWord8)
                    , noBindS $ caseE (varE tagVar) (
                        [ match (litP $ IntegerL i) (normalB $ mkGetBody con) [] | (i, con) <- cons ] ++
                        [ match wildP (normalB $ varE 'fail `appE` errorMsg tagVar) [] ]) ]
      mkGetBody con
          = do (getFunsDecs, getFuns) <- case deriveType of
                                           Normal -> mkSafeFunctions "safeGet_" 'getSafeGet con
                                           _      -> return ([], const 'safeGet)
               let getBase = appE (varE 'return) (conE (conName con))
                   getArgs = foldl (\a t -> infixE (Just a) (varE '(<*>)) (Just (varE (getFuns t)))) getBase (conTypes con)
               doE (getFunsDecs ++ [noBindS getArgs])
      errorMsg tagVar = infixE (Just $ strE str1) (varE '(++)) $ Just $
                        infixE (Just tagStr) (varE '(++)) (Just $ strE str2)
          where
            strE = litE . StringL
            tagStr = varE 'show `appE` varE tagVar
            str1 = "Could not identify tag \""
            str2 = concat [ "\" for type "
                          , show tyName
                          , " that has only "
                          , show (length cons)
                          , " constructors.  Maybe your data is corrupted?" ]

mkSafeFunctions :: String -> Name -> Con -> Q ([StmtQ], Type -> Name)
mkSafeFunctions name baseFun con = do let origTypes = conTypes con
                                      realTypes <- mapM followSynonyms origTypes
                                      finish (zip origTypes realTypes) <$> foldM go ([], []) realTypes
    where go (ds, fs) t
              | found     = return (ds, fs)
              | otherwise = do funVar <- newName (name ++ typeName t)
                               return ( bindS (varP funVar) (varE baseFun) : ds
                                      , (t, funVar) : fs )
              where found = any ((== t) . fst) fs
          finish
            :: [(Type, Type)]            -- "dictionary" from synonyms(or not) to real types
            -> ([StmtQ], [(Type, Name)]) -- statements
            -> ([StmtQ], Type -> Name)   -- function body and name-generator
          finish typeList (ds, fs) = (reverse ds, getName)
              where getName typ = fromMaybe err $ lookup typ typeList >>= flip lookup fs
                    err = error "mkSafeFunctions: never here"

forceTag :: DeriveType -> Bool
forceTag HappstackData = True
forceTag _             = False

-- | Follow type synonyms.  This allows us to see, for example,
-- that @[Char]@ and @String@ are the same type and we just need
-- to call 'getSafePut' or 'getSafeGet' once for both.
followSynonyms :: Type -> Q Type
followSynonyms t@(ConT name)
    = maybe (return t) followSynonyms =<<
      recover (return Nothing) (do info <- reify name
                                   return $ case info of
                                              TyVarI _ ty            -> Just ty
                                              TyConI (TySynD _ _ ty) -> Just ty
                                              _                      -> Nothing)
followSynonyms (AppT ty1 ty2) = liftM2 AppT (followSynonyms ty1) (followSynonyms ty2)
followSynonyms (SigT ty k)    = liftM (flip SigT k) (followSynonyms ty)
followSynonyms t              = return t

conSize :: Con -> Int
conSize (NormalC _name args) = length args
conSize (RecC _name recs)    = length recs
conSize InfixC{}             = 2
conSize ForallC{}            = error "Found constructor with existentially quantified binder. Cannot derive SafeCopy for it."
conSize GadtC{}              = error "Found GADT constructor. Cannot derive SafeCopy for it."
conSize RecGadtC{}           = error "Found GADT constructor. Cannot derive SafeCopy for it."

conName :: Con -> Name
conName (NormalC name _args) = name
conName (RecC name _recs)    = name
conName (InfixC _ name _)    = name
conName _                    = error "conName: never here"

conTypes :: Con -> [Type]
conTypes (NormalC _name args)       = [t | (_, t)    <- args]
conTypes (RecC _name args)          = [t | (_, _, t) <- args]
conTypes (InfixC (_, t1) _ (_, t2)) = [t1, t2]
conTypes _                          = error "conName: never here"

typeName :: Type -> String
typeName (VarT name) = nameBase name
typeName (ConT name) = nameBase name
typeName (TupleT n)  = "Tuple" ++ show n
typeName ArrowT      = "Arrow"
typeName ListT       = "List"
typeName (AppT t u)  = typeName t ++ typeName u
typeName (SigT t _k) = typeName t
typeName _           = "_"

-- * Debugging

traceLoc :: HasCallStack => String -> a -> a
traceLoc s a =
  trace (s <> " (" <> compactStack getStack <> ")") a

traceLocM :: HasCallStack => String -> RWST (R a) W S Q t -> RWST (R a) W S Q t
traceLocM s t = do
  ind <- view indent
  ps <- view params
  bindings <- use bindings
  local (over indent ("  " <>)) $
    trace (ind <> s <> "\n" <>
           ind <> "  --> params: [" <> intercalate ", " (fmap vis ps) <> "]\n" <>
           ind <> "  --> bindings: [" <> intercalate ", " (fmap (\(tv, ty) -> "(tv=" <> vis tv <> ", ty=" <> vis ty <> ")") bindings) <> "]\n" <>
           ind <> "  --> stack: " <> compactStack ({-drop 1-} getStack)) t

ren :: (Data a, Ppr a) => a -> String
ren = renderTH (ppr . everywhere (mkT briefName))

vis :: (Data a, Ppr a) => a -> String
vis = renderTH (ppr . everywhere (mkT briefName'))

-- This will probably make the expression invalid, but it
-- removes random elements that will make tests fail.
briefName :: Name -> Name
briefName (Name oc (NameG _ns _pn _mn)) = Name oc NameS
briefName (Name oc (NameQ _mn)) = Name oc NameS
briefName (Name oc@(OccName _) (NameU _)) = Name oc NameS
briefName name@(Name _ (NameL _)) = name -- Not seeing any of these
briefName name@(Name _ NameS) = name

briefName' :: Name -> Name
briefName' name@(Name oc _nf) | oc == OccName "db" = visName name
briefName' name = briefName name

visName :: Name -> Name
visName (Name oc nf) =
  Name (OccName ("(Name (" <> show oc <> ") (" <> show nf <> "))")) NameS

-- | Stack with main last.  Bottom frame includes the function name.
-- Top frame includes the column number.
compactStack :: forall s. (IsString s, Monoid s, HasCallStack) => [(String, SrcLoc)] -> s
compactStack = mconcat . intersperse (" < " :: s) . compactLocs

compactLocs :: forall s. (IsString s, Monoid s, HasCallStack) => [(String, SrcLoc)] -> [s]
compactLocs [] = ["(no CallStack)"]
compactLocs [(callee, loc)] = [fromString callee, srcloccol loc]
compactLocs [(_, loc), (caller, _)] = [srcloccol loc <> "." <> fromString caller]
compactLocs ((_, loc) : more@((caller, _) : _)) =
  srcfunloc loc (fromString caller) : stacktail (fmap snd more)
  where
    stacktail :: [SrcLoc] -> [s]
    stacktail [] = []
    -- Include the column number of the last item, it may help to
    -- figure out which caller is missing the HasCallStack constraint.
    stacktail [loc'] = [srcloccol loc']
    stacktail (loc' : more') = srcloc loc' : stacktail more'

-- | With start column
srcloccol :: (HasCallStack, IsString s, Semigroup s) => SrcLoc -> s
srcloccol loc = srcloc loc <> ":" <> fromString (show (srcLocStartCol loc))

-- | Compactly format a source location
srcloc :: (IsString s, Semigroup s) => SrcLoc -> s
srcloc loc = fromString (srcLocModule loc) <> ":" <> fromString (show (srcLocStartLine loc))

-- | Compactly format a source location with a function name
srcfunloc :: (IsString s, Semigroup s) => SrcLoc -> s -> s
srcfunloc loc f = fromString (srcLocModule loc) <> "." <> f <> ":" <> fromString (show (srcLocStartLine loc))

-- | Get the portion of the stack before we entered any SeeReason.Log module.
getStack :: HasCallStack => [(String, SrcLoc)]
getStack = dropBoringFrames $ getCallStack callStack
  where
    dropBoringFrames :: [(String, SrcLoc)] -> [(String, SrcLoc)]
    dropBoringFrames = dropWhile (view (_1 . to (`elem` ["getStack", "traceLocM"])))

isThisPackage :: String -> Bool
isThisPackage s = trace ("isThisPackage " <> show s) False

-- * Old versions of the derive function.

-- Versions of the derive functions that take an additional list of
-- type names, not 100% clear what this is for.  I'm hoping the
-- changes to the regular version will supercede these.

deriveSafeCopyIndexedType :: Version a -> Name -> Name -> [Name] -> Q [Dec]
deriveSafeCopyIndexedType versionId kindName tyName =
  internalDeriveSafeCopyIndexedType Normal versionId kindName (conT tyName)

deriveSafeCopyIndexedType' :: Version a -> Name -> TypeQ -> [Name] -> Q [Dec]
deriveSafeCopyIndexedType' versionId kindName typ =
  internalDeriveSafeCopyIndexedType Normal versionId kindName typ

deriveSafeCopySimpleIndexedType :: Version a -> Name -> Name -> [Name] -> Q [Dec]
deriveSafeCopySimpleIndexedType versionId kindName tyName =
  deriveSafeCopySimpleIndexedType' versionId kindName (conT tyName)

deriveSafeCopySimpleIndexedType' :: Version a -> Name -> TypeQ -> [Name] -> Q [Dec]
deriveSafeCopySimpleIndexedType' versionId kindName typ =
  internalDeriveSafeCopyIndexedType Simple versionId kindName typ

deriveSafeCopyHappstackDataIndexedType :: Version a -> Name -> Name -> [Name] -> Q [Dec]
deriveSafeCopyHappstackDataIndexedType versionId kindName tyName =
  deriveSafeCopyHappstackDataIndexedType' versionId kindName (conT tyName)

deriveSafeCopyHappstackDataIndexedType' :: Version a -> Name -> TypeQ -> [Name] -> Q [Dec]
deriveSafeCopyHappstackDataIndexedType' versionId kindName typ =
  internalDeriveSafeCopyIndexedType HappstackData versionId kindName typ

internalDeriveSafeCopyIndexedType :: DeriveType -> Version a -> Name -> TypeQ -> [Name] -> Q [Dec]
internalDeriveSafeCopyIndexedType deriveType versionId kindName typq tyIndex' = do
  tyIndex <- mapM conT tyIndex'
  typq >>= \case
    typ@(ConT tyName) -> do
      let itype = foldl AppT (ConT tyName) tyIndex
      reify tyName >>= \case
        FamilyI _ insts -> do
          concat <$> (forM insts $ withInst2 typ (worker2 deriveType versionId kindName tyIndex' itype))
        info -> fail $ "Can't derive SafeCopy instance for: " ++ show (tyName, info) ++ " (5)"
    typ -> fail $ "Can't derive SafeCopy instance for: " ++ show typ ++ " (6)"

withInst2 ::
  Monad m
  => Type
  -> (Type -> Cxt -> [TyVarBndr] -> [(Integer, Con)] -> m r)
  -> Dec
  -> m r
#if MIN_VERSION_template_haskell(2,15,0)
withInst2 typ worker (DataInstD context _ nty _ cons _) =
  worker nty context [] (zip [0..] cons)
withInst2 typ worker (NewtypeInstD context _ nty _ con _) =
  worker nty context [] (zip [0..] [con])
#else
withInst2 typ worker (DataInstD context _ ty _ cons _) =
  worker (foldl AppT typ ty) context [] (zip [0..] cons)
withInst2 typ worker (NewtypeInstD context _ ty _ con _) =
  worker (foldl AppT typ ty) context [] (zip [0..] [con])
#endif
withInst2 typ _ _ =
  fail $ "Can't derive SafeCopy instance for: " ++ show typ

worker2 :: DeriveType -> Version a -> Name -> [Name] -> Type -> Type -> Cxt -> [TyVarBndr] -> [(Integer, Con)] -> Q [Dec]
worker2 _ _ _ _ itype tyBase _ _ _ | itype /= tyBase =
  fail $ "Expected " <> show itype <> ", but found " <> show tyBase ++ " (7)"
worker2 deriveType versionId kindName tyIndex' _ tyBase context tyvars cons = do
  let ty = foldl AppT tyBase (fmap (\var -> VarT $ tyVarName var) tyvars)
      typeNameStr = unwords (renderTH (ppr . everywhere (mkT cleanName)) ty  : map show tyIndex')
  (:[]) <$> instanceD (cxt (fmap pure (nub context)))
                      (pure (ConT ''SafeCopy `AppT` ty))
                      [ mkPutCopy deriveType cons
                      , mkGetCopy deriveType typeNameStr cons
                      , valD (varP 'version) (normalB $ litE $ integerL $ fromIntegral $ unVersion versionId) []
                      , valD (varP 'kind) (normalB (varE kindName)) []
                      , funD 'errorTypeName [clause [wildP] (normalB $ litE $ StringL typeNameStr) []] ]
