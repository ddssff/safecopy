{-# LANGUAGE TemplateHaskell, NoOverloadedStrings, LambdaCase, FlexibleInstances, CPP #-}

module Data.SafeCopy.Derive where

import Data.Serialize (getWord8, putWord8, label)
import Data.SafeCopy.SafeCopy

import Language.Haskell.TH hiding (Kind)
import Control.Monad
import Data.Data (Data)
import Data.Generics (everywhere, mkT)
import Data.List (nub)
import Data.Maybe (fromMaybe)
#ifdef __HADDOCK__
import Data.Word (Word8) -- Haddock
#endif
import Debug.Trace
import Language.Haskell.TH.PprLib (Doc, to_HPJ_Doc)
import Language.Haskell.TH.Syntax
import qualified Text.PrettyPrint as HPJ

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
deriveSafeCopy versionId kindName tyName =
  internalDeriveSafeCopy Normal versionId kindName tyName (conT tyName)

deriveSafeCopy' :: Version a -> Name -> TypeQ -> Q [Dec]
deriveSafeCopy' versionId kindName typ = internalDeriveSafeCopy Normal versionId kindName typ typ

deriveSafeCopyIndexedType :: Version a -> Name -> Name -> [Name] -> Q [Dec]
deriveSafeCopyIndexedType versionId kindName tyName =
  internalDeriveSafeCopyIndexedType Normal versionId kindName (conT tyName)

deriveSafeCopyIndexedType' :: Version a -> Name -> TypeQ -> [Name] -> Q [Dec]
deriveSafeCopyIndexedType' versionId kindName typ =
  internalDeriveSafeCopyIndexedType Normal versionId kindName typ

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
deriveSafeCopySimple' versionId kindName typ =
  internalDeriveSafeCopy Simple versionId kindName typ typ

deriveSafeCopySimpleIndexedType :: Version a -> Name -> Name -> [Name] -> Q [Dec]
deriveSafeCopySimpleIndexedType versionId kindName tyName =
  deriveSafeCopySimpleIndexedType' versionId kindName (conT tyName)

deriveSafeCopySimpleIndexedType' :: Version a -> Name -> TypeQ -> [Name] -> Q [Dec]
deriveSafeCopySimpleIndexedType' versionId kindName typ =
  internalDeriveSafeCopyIndexedType Simple versionId kindName typ

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
  deriveSafeCopyHappstackData' versionId kindName (conT tyName) tyName

deriveSafeCopyHappstackData' :: ExtraContext t => Version a -> Name -> TypeQ -> t -> Q [Dec]
deriveSafeCopyHappstackData' versionId kindName typq t =
  internalDeriveSafeCopy HappstackData versionId kindName t typq

deriveSafeCopyHappstackDataIndexedType :: Version a -> Name -> Name -> [Name] -> Q [Dec]
deriveSafeCopyHappstackDataIndexedType versionId kindName tyName =
  deriveSafeCopyHappstackDataIndexedType' versionId kindName (conT tyName)

deriveSafeCopyHappstackDataIndexedType' :: Version a -> Name -> TypeQ -> [Name] -> Q [Dec]
deriveSafeCopyHappstackDataIndexedType' versionId kindName typ =
  internalDeriveSafeCopyIndexedType HappstackData versionId kindName typ

data DeriveType = Normal | Simple | HappstackData

forceTag :: DeriveType -> Bool
forceTag HappstackData = True
forceTag _             = False

#if MIN_VERSION_template_haskell(2,17,0)
tyVarName :: TyVarBndr s -> Name
tyVarName (PlainTV n _) = n
tyVarName (KindedTV n _ _) = n
#else
tyVarName :: TyVarBndr -> Name
tyVarName (PlainTV n) = n
tyVarName (KindedTV n _) = n
#endif

class ExtraContext a where
  extraContext :: a -> Q Cxt

instance (ExtraContext a, ExtraContext b) => ExtraContext (a, b) where
  extraContext (a, b) = (<>) <$> extraContext a <*> extraContext b

-- | Generate SafeCopy constraints for a list of type variables
instance ExtraContext Cxt where
  extraContext context = pure context

instance ExtraContext [TyVarBndr] where
  extraContext tyvars =
    sequence (fmap (\var -> [t|SafeCopy $(varT (tyVarName var))|]) tyvars)

instance ExtraContext Name where
  extraContext tyName =
    reify tyName >>= \case
      TyConI (DataD _ _ tyvars _ _ _) -> extraContext tyvars
      TyConI (NewtypeD _ _ tyvars _ _ _) -> extraContext tyvars
      FamilyI _ _ -> pure []
      info -> fail $ "Can't derive SafeCopy instance for: " ++ show (tyName, info)

instance ExtraContext TypeQ where
  extraContext typq =
    typq >>= \case
      ConT tyName -> extraContext tyName
      ForallT _ context _ -> pure context
      typ -> fail $ "Can't derive SafeCopy instance for: " ++ show typ

instance ExtraContext Con where
  extraContext (NormalC name types) =
    fmap mconcat (sequence <$> mapM extraContext (fmap snd types))
  extraContext (RecC name types) =
    fmap mconcat (sequence <$> mapM extraContext (fmap (\(_, _, typ) -> typ) types))
  extraContext (InfixC type1 name type2) = extraContext (snd type1, snd type2)
  extraContext (ForallC tyvars context con) = (<>) <$> pure context <*> extraContext con
  extraContext (GadtC names types typ) = pure []
  extraContext (RecGadtC names types typ) = pure []

instance ExtraContext Type where
  extraContext typ = sequence [ [t|SafeCopy $(pure typ)|] ]

internalDeriveSafeCopy :: ExtraContext t => DeriveType -> Version a -> Name -> t -> TypeQ -> Q [Dec]
internalDeriveSafeCopy deriveType versionId kindName t typq = do
  typq >>= \case
    ConT tyName -> doInfo deriveType versionId kindName t tyName =<< reify tyName
    ForallT _ cxt' typ' -> internalDeriveSafeCopy deriveType versionId kindName cxt' (pure typ')
    AppT t1 _t2 -> internalDeriveSafeCopy deriveType versionId kindName t (pure t1)
    TupleT n -> let tyName = tupleTypeName n in doInfo deriveType versionId kindName t tyName =<< reify tyName
    typ -> fail $ "Can't derive SafeCopy instance for: " ++ show typ

doInfo :: ExtraContext t => DeriveType -> Version a -> Name -> t -> Name -> Info -> Q [Dec]
doInfo deriveType versionId kindName t tyName info =
  case info of
    TyConI (DataD context _name tyvars _kind cons _derivs)
      | length cons > 255 -> fail $ "Can't derive SafeCopy instance for: " ++ show tyName ++
                                    ". The datatype must have less than 256 constructors."
      | otherwise -> do
          extra <- extraContext t
          doCons deriveType versionId kindName tyName (ConT tyName) (context ++ extra) tyvars (zip [0..] cons)

    TyConI (NewtypeD context _name tyvars _kind con _derivs) ->
      doCons deriveType versionId kindName tyName (ConT tyName) context tyvars (zip [0..] [con])

    FamilyI _ insts -> do
      concat <$> (forM insts $ withInst (ConT tyName) (doCons deriveType versionId kindName tyName))
    _ -> fail $ "Can't derive SafeCopy instance for: " ++ show (tyName, info)

internalDeriveSafeCopyIndexedType :: DeriveType -> Version a -> Name -> TypeQ -> [Name] -> Q [Dec]
internalDeriveSafeCopyIndexedType deriveType versionId kindName typq tyIndex' = do
  tyIndex <- mapM conT tyIndex'
  typq >>= \case
    typ@(ConT tyName) -> do
      let itype = foldl AppT (ConT tyName) tyIndex
      reify tyName >>= \case
        FamilyI _ insts -> do
          concat <$> (forM insts $ withInst typ (worker2 deriveType versionId kindName tyIndex' itype))
        info -> fail $ "Can't derive SafeCopy instance for: " ++ show (tyName, info)
    typ -> fail $ "Can't derive SafeCopy instance for: " ++ show typ
  where

renderDecs :: [Dec] -> String
renderDecs = renderTH (ppr . everywhere (mkT briefName))

doCons :: DeriveType -> Version a -> Name -> Name -> Type -> Cxt -> [TyVarBndr] -> [(Integer, Con)] -> Q [Dec]
doCons deriveType versionId kindName tyName tyBase context tyvars cons = do
  let ty = foldl AppT tyBase (fmap (\var -> VarT $ tyVarName var) tyvars)
  extra <- concat <$> mapM extraContext (fmap snd cons)
  (:[]) <$> instanceD (cxt (fmap pure (nub (context <> extra))))
                      (pure (ConT ''SafeCopy `AppT` ty))
                      [ mkPutCopy deriveType cons
                      , mkGetCopy deriveType (renderTH (ppr . everywhere (mkT cleanName)) (ConT tyName)) cons
                      , valD (varP 'version) (normalB $ litE $ integerL $ fromIntegral $ unVersion versionId) []
                      , valD (varP 'kind) (normalB (varE kindName)) []
                      , funD 'errorTypeName [clause [wildP] (normalB $ litE $ StringL (renderTH (ppr . everywhere (mkT cleanName)) (ConT tyName))) []] ]

worker2 :: DeriveType -> Version a -> Name -> [Name] -> Type -> Type -> Cxt -> [TyVarBndr] -> [(Integer, Con)] -> Q [Dec]
worker2 _ _ _ _ itype tyBase _ _ _ | itype /= tyBase =
  fail $ "Expected " <> show itype <> ", but found " <> show tyBase
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

withInst ::
  Monad m
  => Type
  -> (Type -> Cxt -> [TyVarBndr] -> [(Integer, Con)] -> m r)
  -> Dec
  -> m r
#if MIN_VERSION_template_haskell(2,15,0)
withInst typ worker (DataInstD context _ nty _ cons _) =
  worker nty context [] (zip [0..] cons)
withInst typ worker (NewtypeInstD context _ ty _ con _) =
  worker nty context [] (zip [0..] [con])
#else
withInst typ worker (DataInstD context _ ty _ cons _) =
  worker (foldl AppT typ ty) context [] (zip [0..] cons)
withInst typ worker (NewtypeInstD context _ ty _ con _) =
  worker (foldl AppT typ ty) context [] (zip [0..] [con])
#endif
withInst typ _ _ =
  fail $ "Can't derive SafeCopy instance for: " ++ show typ

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

-- | Apply the TH pretty printer to a value after stripping any added
-- suffixes from its names.  This may make it uncompilable, but it
-- eliminates a source of randomness in the expected and actual test
-- case results.
renderTH :: Data a => (a -> Doc) -> a -> String
renderTH pretty decs =
  -- fixNames $
  HPJ.renderStyle (HPJ.style {HPJ.lineLength = 1000000 {-HPJ.mode = HPJ.OneLineMode-}}) $
  to_HPJ_Doc $
  pretty $
  {-fixText-} decs

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

-- This will probably make the expression invalid, but it
-- removes random elements that will make tests fail.
briefName :: Name -> Name
briefName (Name oc (NameG _ns _pn _mn)) = Name oc NameS
briefName (Name oc (NameQ _mn)) = Name oc NameS
briefName (Name oc@(OccName _) (NameU _)) = Name oc NameS
briefName name@(Name _ (NameL _)) = name -- Not seeing any of these
briefName name@(Name _ NameS) = name

ws :: String
ws = "(\t|\r|\n| |,)*"
ch :: String
ch = "'([^'\\\\]|\\\\')'"
