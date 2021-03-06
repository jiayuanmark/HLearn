{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE RebindableSyntax #-}

import Control.Monad
import Data.List (zip,intersperse,init,tail,isSuffixOf)
import Data.Maybe (fromJust)
import qualified Data.Vector.Generic as VG
import Data.Version
import Numeric
import System.Console.CmdArgs.Implicit
import System.IO

import qualified Prelude as P
import SubHask
import SubHask.Algebra.Container
import SubHask.Algebra.Ord
import SubHask.Compatibility.Containers
import SubHask.Compatibility.Vector.HistogramMetrics
import SubHask.Compatibility.Vector.Lebesgue
-- import SubHask.Monad

import Data.Params

import HLearn.Data.Graph
import HLearn.Data.LoadData
import HLearn.Data.SpaceTree
import HLearn.Data.SpaceTree.CoverTree hiding (head,tail)
import HLearn.Data.SpaceTree.Algorithms.NearestNeighbor
import HLearn.Data.UnsafeVector
import HLearn.History.Timing
import HLearn.Models.Distributions.Common
import HLearn.Models.Distributions.Univariate.Normal

import Paths_HLearn


-------------------------------------------------------------------------------
-- command line parameters

data Params = Params
    { k                 :: Int
    , kForceSlow        :: Bool

    , data_format       :: DataFormat
    , reference_file    :: Maybe String
    , query_file        :: Maybe String
    , distances_file    :: String
    , neighbors_file    :: String

    , train_method      :: TrainMethod
    , adopt_children    :: Bool
    , train_sequential  :: Bool
    , cache_dists       :: Bool
    , pca_data          :: Bool
    , varshift_data     :: Bool

    , searchEpsilon     :: Float
    , expansionRatio    :: Float

    , packMethod        :: PackMethod
    , sortMethod        :: SortMethod

    , verbose           :: Bool
    , debug             :: Bool
    }
    deriving (Show, Data, Typeable)

data TrainMethod
    = TrainInsert_NoSort
    | TrainInsert_Sort
    | TrainInsert_Parent
    | TrainInsert_Ancestor
    | TrainMonoid
    deriving (Read,Show,Data,Typeable)

data PackMethod
    = NoPack
    | PackCT
    | PackCT2
    | PackCT3
    | SetLeaves
    deriving (Read,Show,Data,Typeable)

data SortMethod
    = NoSort
    | NumDP_Distance
    | NumDP_Distance'
    | Distance_NumDP
    | Distance_NumDP'
    deriving (Read,Show,Data,Typeable)

data DataFormat
    = DF_CSV
    | DF_PLG
    | DF_Images
    | DF_BagOfWords
    | DF_String
    deriving (Read,Show,Data,Typeable)

allknnParams = Params
    { k              = 1
                    &= help "Number of nearest neighbors to find"

    , reference_file = def
                    &= help "Reference data set"
                    &= typFile

    , data_format    = DF_CSV
                    &= help "file format of data files"

    , query_file     = def
                    &= help "Query data set"
                    &= typFile

    , distances_file = "distances_hlearn.csv"
                    &= help "File to output distances into"
                    &= typFile

    , neighbors_file = "neighbors_hlearn.csv"
                    &= help "File to output the neighbors into"
                    &= typFile

    , searchEpsilon   = 0
                    &= help ""
                    &= groupname "Approximations"

    , expansionRatio = 1.3
                    &= help ""
                    &= groupname "Approximations"

    , packMethod     = PackCT
                    &= help "Specifies which method to use for cache layout of the covertree"
                    &= groupname "Tree structure optimizations"

    , sortMethod     = NumDP_Distance
                    &= help "What order should the children be sorted in?"

    , kForceSlow     = False
                    &= help "Don't use precompiled k function; use the generic one"

    , train_sequential = False
                    &= help "don't train the tree in parallel; this may *slightly* speed up the nearest neighbor search at the expense of greatly slowing tree construction"

    , train_method   = TrainInsert_NoSort
                    &= help "which method to use to construct the cover tree?"

    , adopt_children = False
                    &= help "move children to uncle nodes when they're closer than parents"

    , cache_dists    = True
                    &= help "pre-calculate the maximum distance from any node dp to all of its descendents; speeds up queries at the expense of O(n log n) overhead in construction"

    , pca_data       = False
                    &= groupname "Data Preprocessing"
                    &= help "Rotate the data points using the PCA transform.  Speeds up nearest neighbor searches, but computing the PCA can be expensive in many dimensions."
                    &= name "pca"
                    &= explicit

    , varshift_data  = True
                    &= help "Sort the attributes according to their variance.  Provides almost as much speed up as the PCA transform during neighbor searches, but much less expensive to compute."
                    &= name "varshift"
                    &= explicit

    , verbose        = False
                    &= help "Print tree statistics (takes some extra time)"
                    &= groupname "Debugging"

    , debug          = False
                    &= help "Test created trees for validity (takes lots of time)"
                    &= name "runtests"
                    &= explicit
    }
    &= summary ("HLearn k-nearest neighbor, version " ++ showVersion version)

-------------------------------------------------------------------------------
-- main

main = do

    -- validate the cmd line args
    params <- cmdArgs allknnParams

    when (reference_file params == Nothing) $
        error "must specify a reference file"

    when (searchEpsilon params < 0) $
        error "search epsilon must be >= 0"

    -- load the data
    let filepath = fromJust $ reference_file params

    case data_format params of
        DF_CSV -> do
            let l2nl=Proxy::Proxy (NeighborList (Static 1) (L2 UnboxedVector Float))
                l2ct=Proxy::Proxy (CoverTree_ (13/10) Array UnboxedArray (L2 UnboxedVector Float))
            let dataparams = DataParams
                    { datafile = filepath
                    , labelcol = Nothing
                    , pca      = pca_data params
                    , varshift = varshift_data params
                    }
            rs <- loaddata dataparams

            runTest params rs Nothing l2ct l2nl

--         DF_Images -> do
--             let nl=Proxy::Proxy (NeighborList (Static 1) HistogramSignature)
--                 ct=Proxy::Proxy (CoverTree_ (13/10) Array Array HistogramSignature)
--             rs <- loadDirectory
--                 filepath
--                 (loadHistogramSignature False)
--                 (isSuffixOf ".sig.all")
--                 true
--             runTest params rs Nothing ct nl

--         DF_PLG -> do
--             let nl=Proxy::Proxy (NeighborList (Static 1) Graph)
--                 ct=Proxy::Proxy (CoverTree_ (13/10) Array Array Graph)
--             rs <- timeIO "loadDirectory_PLG" $ loadDirectory_PLG filepath
--             runTest params rs Nothing ct nl

--         DF_String -> do
--             let wordsnl=Proxy::Proxy (NeighborList (Static 1) (Lexical (Levenshtein (UnboxedArray Char))))
--                 wordsct=Proxy::Proxy (CoverTree_ (13/10) Array Array (Lexical (Levenshtein (UnboxedArray Char))))
--
--             rs <- loadWords filepath
--             timeIO "loading data" $ return rs
--             runTest params rs Nothing wordsct wordsnl
--
--         DF_BagOfWords -> do
--             let bownl=Proxy::Proxy (NeighborList (Static 1) (Map' Int Float))
--                 bowct=Proxy::Proxy (CoverTree_ (13/10) Array Array (Map' Int Float))
--
--             let dataparams = DataParams
--             rs <- loadBagOfWords filepath
--             timeIO "loading data" $ return rs
--             runTest params rs Nothing bowct bownl


--     runTest params (undefined :: Tree) (undefined :: NeighborList (Static 1) DP)
--     if kForceSlow params || k params > 3
--         then do
--             putStrLn "WARNING: using slow version of k"
--             apWith1Param'
--                 (undefined :: NeighborList RunTime DP)
--                 _k
--                 (k params)
--                 (runTest params (undefined::Tree))
--                 (undefined :: NeighborList RunTime DP)
--         else case k params of
--             1 -> runTest params (undefined :: Tree) (undefined :: NeighborList (Static 1) DP)
--             2 -> runTest params (undefined :: Tree) (undefined :: NeighborList (Static 2) DP)
--             3 -> runTest params (undefined :: Tree) (undefined :: NeighborList (Static 3) DP)
--             4 -> runTest params (undefined :: Tree) (undefined :: NeighborList (Static 4) DP)
--             5 -> runTest params (undefined :: Tree) (undefined :: NeighborList (Static 5) DP)
--             100 -> runTest params (undefined :: Tree) (undefined :: NeighborList (Static 100) DP)

-- {-# SPECIALIZE runTest
--         :: Params
--         -> Array (L2 UnboxedVector Float)
--         -> Proxy (Maybe' (CoverTree_ (13/10) Array UnboxedArray (L2 UnboxedVector Float)))
--         -> Proxy (NeighborList (Static 1) (L2 UnboxedVector Float))
--         -> IO ()
--         #-}
--             let l2nl=Proxy::Proxy
--                 l2ct=Proxy::Proxy (
-- {-# SPECIALIZE runTest :: Params -> Tree -> NeighborList (Static 1) DP -> IO () #-}
-- {-# SPECIALIZE runTest :: Params -> Tree -> NeighborList (Static 2) DP -> IO () #-}
-- {-# SPECIALIZE runTest :: Params -> Tree -> NeighborList (Static 3) DP -> IO () #-}
-- {-# SPECIALIZE runTest :: Params -> Tree -> NeighborList (Static 4) DP -> IO () #-}
-- {-# SPECIALIZE runTest :: Params -> Tree -> NeighborList (Static 5) DP -> IO () #-}
-- {-# SPECIALIZE runTest :: Params -> Tree -> NeighborList (Static 100) DP -> IO () #-}
-- {-# SPECIALIZE runTest :: Param_k (NeighborList RunTime DP) => Params -> Tree -> NeighborList RunTime DP -> IO ()#-}


-- | Given our data, perform the actual tests.
-- For efficiency, it is extremely important that this function get specialized to the exact types it is called on.
{-# INLINE runTest #-}
runTest :: forall k exprat childC leafC dp proxy1 proxy2.
    ( ValidCT exprat childC leafC dp
    , P.Fractional (Scalar dp)
    , Param_k (NeighborList k dp)
    , RationalField (Scalar dp)
    , VG.Vector childC Int
    , VG.Vector childC Bool
    , ValidNeighbor dp
    ) => Params
      -> Array dp
      -> Maybe (Array dp)
      -> proxy1 (CoverTree_ exprat childC leafC dp)
      -> proxy2 (NeighborList k dp)
      -> IO ()
runTest params rs mqs tree knn = do

    -- build the trees
    reftree <- buildTree params rs :: IO (CoverTree_ exprat childC leafC dp)

    (querytree,qs) <- case mqs of
        Nothing -> return $ (reftree,rs)
        Just qs -> do
            querytree <- buildTree params qs
            return (querytree, qs)

    -- do knn search
    let res = parallel
            ( findAllNeighbors (convertRationalField $ searchEpsilon params) reftree  )
            ( stToList querytree )
            :: Seq (dp, NeighborList k dp)
    time "computing parFindNeighborMap" res

    -- output to files
    let qs_index = parallel fromList $ zip (VG.toList qs) [0::Int ..] :: Map' dp Int
        rs_index = case mqs of
            Nothing -> qs_index
            Just _  -> parallel fromList $ zip (VG.toList rs) [0::Int ..] :: Map' dp Int
    time "qs_index" qs_index
    time "rs_index" rs_index

    let sortedResults :: [[Neighbor dp]]
        sortedResults =
            ( map getknnL
            . values
            . parallel
                ( mapIndices (qs_index!)
                . fromList
                . toList
                )
            ) res
    time "sorting results" sortedResults

    -- output distances
    let distanceL = map (map neighborDistance) sortedResults

    timeIO "outputing distance" $ do
        hDistances <- openFile (distances_file params) WriteMode
        forM_ distanceL (hPutStrLn hDistances . init . tail . show)
        hClose hDistances

    -- output neighbors
    let neighborL = {-parallel-} (map (map ((rs_index!) . neighbor))) sortedResults
    time "finding neighbors" neighborL

    timeIO "outputting neighbors" $ do
        hNeighbors <- openFile (neighbors_file params) WriteMode
        forM_ neighborL (hPutStrLn hNeighbors . init . tail . show)
        hClose hNeighbors

    putStrLn "done"

{-# RULES

"subhask/parallel"     forall f g x. parallel f (parallel g x) = parallel (f.g) x

  #-}


{-# RULES

"subhask/fromtoList"     forall x. fromList (toList x) = x
"subhask/tofromList"     forall x. toList (fromList x) = x

  #-}


{-# RULES

"subhask/eqVectorDouble"  (==) = eqVectorDouble
"subhask/eqVectorFloat"  (==) = eqVectorFloat
"subhask/eqVectorInt"  (==) = eqVectorInt
"subhask/eqUnboxedVectorDouble"  (==) = eqUnboxedVectorDouble
"subhask/eqUnboxedVectorFloat"  (==) = eqUnboxedVectorFloat
"subhask/eqUnboxedVectorInt"  (==) = eqUnboxedVectorInt

-- "subhask/distance_l2_float_unboxed"         distance = distance_l2_float_unboxed
-- "subhask/isFartherThan_l2_float_unboxed"    isFartherThanWithDistanceCanError=isFartherThan_l2_float_unboxed
-- "subhask/distance_l2_m128_unboxed"         distance = distance_l2_m128_unboxed
-- "subhask/isFartherThan_l2_m128_unboxed"    isFartherThanWithDistanceCanError=isFartherThan_l2_m128_unboxed

-- "subhask/distance_l2_m128_storable"        distance = distance_l2_m128_storable
-- "subhask/distance_l2_m128d_storable"       distance = distance_l2_m128d_storable
-- "subhask/isFartherThan_l2_m128_storable"   isFartherThanWithDistanceCanError=isFartherThan_l2_m128_storable
-- "subhask/isFartherThan_l2_m128d_storable"  isFartherThanWithDistanceCanError=isFartherThan_l2_m128d_storable

  #-}

-- {-# SPECIALIZE insertCT
--     :: KnownFrac exprat
--     => AddChildMethod (L2 UnboxedVector Float)
--     -> L2 UnboxedVector Float
--     -> CoverTree_ exprat Array UnboxedArray (L2 UnboxedVector Float)
--     -> CoverTree_ exprat Array UnboxedArray (L2 UnboxedVector Float)
--   #-}
-- | Gives us many possible ways to construct our cover trees based on the input parameters.
-- This is important so we can compare their runtime features.
buildTree :: forall exprat childC leafC dp.
    ( ValidCT exprat childC leafC dp
    , VG.Vector childC Bool
    , VG.Vector childC Int
    ) => Params
      -> Array dp
      -> IO (CoverTree_ exprat childC leafC dp)
buildTree params xs = do

    setexpratIORef $ P.toRational $ expansionRatio params

    let trainmethod = case train_method params of
            TrainInsert_NoSort   -> trainInsertNoSort
            TrainInsert_Sort     -> trainInsert addChild_nothing
            TrainInsert_Parent   -> trainInsert addChild_parent
            TrainInsert_Ancestor -> trainInsert addChild_ancestor
            TrainMonoid          -> trainMonoid

    let (Just' reftree) = parallel trainmethod xs
    time "building tree" reftree

    let reftree_adopt = if adopt_children params
            then ctAdoptNodes reftree
            else reftree
    time "adopting" reftree_adopt

    let reftree_sort = case sortMethod params of
            NoSort -> reftree_adopt
            NumDP_Distance  -> sortChildren cmp_numdp_distance  reftree_adopt
            NumDP_Distance' -> sortChildren cmp_numdp_distance' reftree_adopt
            Distance_NumDP  -> sortChildren cmp_distance_numdp  reftree_adopt
            Distance_NumDP' -> sortChildren cmp_distance_numdp' reftree_adopt
    time "sorting children" reftree_sort

    let reftree_prune = case packMethod params of
            NoPack    -> reftree_sort
            SetLeaves -> setLeaves 0 $ reftree_sort
            PackCT    -> packCT $ setLeaves 0 $ reftree_sort
    time "packing reference tree" reftree_prune

    let reftree_cache = if cache_dists params
            then setMaxDescendentDistance reftree_prune
            else reftree_prune
    time "caching distances" reftree_cache

    when (verbose params) $ do
        putStrLn ""
        printTreeStats "reftree      " $ reftree
        printTreeStats "reftree_prune" $ reftree_prune

    return reftree_cache

-- | Print out debugging information about our cover trees.
--
-- FIXME:
-- Make this more generic so it works on any space tree.
-- Should this be moved into the SpaceTree file?
printTreeStats ::
    ( ValidCT exprat childC leafC dp
    , VG.Vector childC Bool
    , VG.Vector childC Int
    ) => String
      -> CoverTree_ exprat childC leafC dp
      -> IO ()
printTreeStats str t = do
    putStrLn (str++" st stats:")
    putStr (str++"  stNumDp..............") >> hFlush stdout >> putStrLn (show $ stNumDp t)
    putStr (str++"  stNumNodes...........") >> hFlush stdout >> putStrLn (show $ stNumNodes t)
    putStr (str++"  stNumLeaves..........") >> hFlush stdout >> putStrLn (show $ stNumLeaves t)
    putStr (str++"  stNumGhosts..........") >> hFlush stdout >> putStrLn (show $ stNumGhosts t)
    putStr (str++"  stNumGhostSingletons.") >> hFlush stdout >> putStrLn (show $ stNumGhostSingletons t)
    putStr (str++"  stNumGhostLeaves.....") >> hFlush stdout >> putStrLn (show $ stNumGhostLeaves t)
    putStr (str++"  stNumGhostSelfparent.") >> hFlush stdout >> putStrLn (show $ stNumGhostSelfparent t)
    putStr (str++"  stAveGhostChildren...") >> hFlush stdout >> putStrLn (show $ mean $ stAveGhostChildren t)
    putStr (str++"  stMaxLeaves..........") >> hFlush stdout >> putStrLn (show $ stMaxLeaves t)
    putStr (str++"  stAveLeaves..........") >> hFlush stdout >> putStrLn (show $ mean $ stAveLeaves t)
    putStr (str++"  stMaxChildren........") >> hFlush stdout >> putStrLn (show $ stMaxChildren t)
    putStr (str++"  stAveChildren........") >> hFlush stdout >> putStrLn (show $ mean $ stAveChildren t)
    putStr (str++"  stMaxDepth...........") >> hFlush stdout >> putStrLn (show $ stMaxDepth t)
    putStr (str++"  stNumSingletons......") >> hFlush stdout >> putStrLn (show $ stNumSingletons t)
    putStr (str++"  stExtraLeaves........") >> hFlush stdout >> putStrLn (show $ stExtraLeaves t)
    putStrLn (str++" ct stats:")
    putStr (str++"  ctMaxCoverRatio........") >> hFlush stdout >> putStrLn (show $ ctMaxCoverRatio t)
    putStr (str++"  ctAveCoverRatio........") >> hFlush stdout >> putStrLn (show $ mean $ ctAveCoverRatio t)
    putStr (str++"  ctMovableNodes.........") >> hFlush stdout >> putStrLn (show $ ctMovableNodes t)
    putStr (str++"  ctBetterMovableNodes...") >> hFlush stdout >> putStrLn (show $ ctBetterMovableNodes t)
    putStr (str++"  ctMovableParents.......") >> hFlush stdout >> putStrLn (show $ ctMovableParents t)
    putStr (str++"  ctBetterMovableParents.") >> hFlush stdout >> putStrLn (show $ ctBetterMovableParents t)

    putStrLn (str++" invariants:")
    putStr (str++"  covering.....") >> hFlush stdout >> putStrLn (show $ invariant_CoverTree_covering t)
    putStr (str++"  tightCover...") >> hFlush stdout >> putStrLn (show $ invariant_CoverTree_tightCovering t)
    putStr (str++"  separating...") >> hFlush stdout >> putStrLn (show $ invariant_CoverTree_separating t)
    putStr (str++"  maxDescDist..") >> hFlush stdout >> putStrLn (show $ invariant_CoverTree_maxDescendentDistance t)
    putStr (str++"  leveled......") >> hFlush stdout >> putStrLn (show $ property_leveled t)

    putStrLn ""
