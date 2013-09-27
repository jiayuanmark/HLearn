
{-# LANGUAGE DataKinds #-}

module HLearn.DataStructures.SpaceTree.Algorithms.NearestNeighbor
    where

import Debug.Trace

import Control.Monad
import Control.Monad.ST
import Control.DeepSeq
import Data.List
import qualified Data.Foldable as F
import qualified Data.Map.Strict as Map
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as VM

import HLearn.Algebra
import HLearn.DataStructures.SpaceTree

-------------------------------------------------------------------------------
-- data types 

data Neighbor dp = Neighbor
    { neighbor         :: !dp
    , neighborDistance :: !(Ring dp)
    }

deriving instance (Read dp, Read (Ring dp)) => Read (Neighbor dp)
deriving instance (Show dp, Show (Ring dp)) => Show (Neighbor dp)

instance Eq (Ring dp) => Eq (Neighbor dp) where
    a == b = neighborDistance a == neighborDistance b

instance Ord (Ring dp) => Ord (Neighbor dp) where
    compare a b = compare (neighborDistance a) (neighborDistance b)

instance (NFData dp, NFData (Ring dp)) => NFData (Neighbor dp) where
    rnf n = deepseq (neighbor n) $ rnf (neighborDistance n)

---------------------------------------

newtype KNN (k::Nat) dp = KNN { getknn :: [Neighbor dp] }
-- newtype KNN (k::Nat) dp = KNN { getknn :: V.Vector (Neighbor dp) }

deriving instance (Read dp, Read (Ring dp)) => Read (KNN k dp)
deriving instance (Show dp, Show (Ring dp)) => Show (KNN k dp)
deriving instance (NFData dp, NFData (Ring dp)) => NFData (KNN k dp)

knn_maxdist :: forall k dp. (SingI k,Ord dp,Fractional (Ring dp)) => KNN k dp -> Ring dp
knn_maxdist (KNN v) = if length v > 0
    then neighborDistance $ last v 
    else infinity

---------------------------------------

newtype KNN2 (k::Nat) dp = KNN2 
    { getknn2 :: Map.Map dp (KNN k dp) 
    }

deriving instance (Read dp, Read (Ring dp), Ord dp, Read (KNN k dp)) => Read (KNN2 k dp)
deriving instance (Show dp, Show (Ring dp), Ord dp, Show (KNN k dp)) => Show (KNN2 k dp)
deriving instance (NFData dp, NFData (Ring dp)) => NFData (KNN2 k dp)

instance (SpaceTree t dp, F.Foldable t, Ord dp, SingI k) => Function (KNN2 k dp) (DualTree (t dp)) (KNN2 k dp) where
    function _ = knn2

-------------------------------------------------------------------------------
-- algebra

instance (SingI k, MetricSpace dp, Eq dp) => Monoid (KNN k dp) where
    mempty = KNN mempty 
    mappend (KNN xs) (KNN ys) = KNN $ take k $ interleave xs ys
        where
            k=fromIntegral $ fromSing (sing :: Sing k)

instance (SingI k, MetricSpace dp, Ord dp) => Monoid (KNN2 k dp) where
    mempty = KNN2 mempty
    mappend (KNN2 x) (KNN2 y) = KNN2 $ Map.unionWith (<>) x y

-------------------------------------------------------------------------------
-- dual tree

knn2 :: (SpaceTree t dp, F.Foldable t, Ord dp, SingI k) => DualTree (t dp) -> KNN2 k dp
knn2=knn2_single

knn2_fast :: (SpaceTree t dp, Ord dp, SingI k) => DualTree (t dp) -> KNN2 k dp
knn2_fast = prunefold2init initKNN2 knn2_prune knn2_cata

knn2_slow :: (SpaceTree t dp, Ord dp, SingI k) => DualTree (t dp) -> KNN2 k dp
knn2_slow = prunefold2init initKNN2 noprune knn2_cata

initKNN2 :: SpaceTree t dp => DualTree (t dp) -> KNN2 k dp
initKNN2 dual = KNN2 $ Map.singleton qnode val
    where
        rnode = stNode $ reference dual
        qnode = stNode $ query dual
        val = KNN [Neighbor rnode (distance qnode rnode)]

knn2_prune :: forall k t dp. (SingI k, SpaceTree t dp, Ord dp) => KNN2 k dp -> DualTree (t dp) -> Bool
knn2_prune knn2 dual = stMinDistance (reference dual) (query dual) > bound
    where
        bound = maxdist knn2 (reference dual)

dist :: forall k t dp. (SingI k, MetricSpace dp, Ord dp) => KNN2 k dp -> dp -> Ring dp
dist knn2 dp = knn_maxdist $ Map.findWithDefault mempty dp $ getknn2 knn2

maxdist :: forall k t dp. (SingI k, SpaceTree t dp, Ord dp) => KNN2 k dp -> t dp -> Ring dp
maxdist knn2 tree = if stIsLeaf tree
    then dist knn2 (stNode tree) 
    else maximum
        $ (dist knn2 (stNode tree))
        : (fmap (maxdist knn2) $ stChildren tree)

knn2_cata :: (SingI k, Ord dp, MetricSpace dp) => DualTree dp -> KNN2 k dp -> KNN2 k dp 
knn2_cata !dual !knn2 = KNN2 $ Map.insertWith (<>) qnode knn' $ getknn2 knn2
    where
        rnode = reference dual 
        qnode = query dual 
        dualdist = distance rnode qnode
        knn' = if rnode == qnode
            then mempty
            else KNN $ [Neighbor rnode dualdist]


-------------------------------------------------------------------------------
-- single tree

init_neighbor :: SpaceTree t dp => dp -> t dp -> Neighbor dp
init_neighbor query t = Neighbor
    { neighbor = stNode t
    , neighborDistance = distance query (stNode t)
    }

nearestNeighbor :: SpaceTree t dp => dp -> t dp -> Neighbor dp
nearestNeighbor query t = prunefoldinit (init_neighbor query) (nn_prune query) (nn_cata query) t

nearestNeighbor_slow :: SpaceTree t dp => dp -> t dp -> Neighbor dp
nearestNeighbor_slow query t = prunefoldinit (init_neighbor query) noprune (nn_cata query) t

nn_prune :: SpaceTree t dp => dp -> Neighbor dp -> t dp -> Bool
nn_prune query b t = neighborDistance b < distance query (stNode t)

nn_cata :: MetricSpace dp => dp -> dp -> Neighbor dp -> Neighbor dp
nn_cata query next current = if neighborDistance current < nextDistance
    then current
    else Neighbor next nextDistance
    where
        nextDistance = distance query next

---------------------------------------

knn :: (SingI k, SpaceTree t dp, Eq dp) => dp -> t dp -> KNN k dp
knn query t = prunefoldmempty (knn_prune query) (knn_cata query) t

knn_slow :: (SingI k, SpaceTree t dp, Eq dp) => dp -> t dp -> KNN k dp
knn_slow query t = prunefold noprune (knn_cata query) mempty t

knn_prune :: forall k t dp. (SingI k, SpaceTree t dp) => dp -> KNN k dp -> t dp -> Bool
knn_prune query res t = knnMaxDistance res < (stMinDistanceDp t query) && isFull res
    where
        k = fromIntegral $ fromSing (sing :: Sing k)

        isFull knn = length (getknn knn) >= k

        knnMaxDistance (KNN []) = infinity
        knnMaxDistance (KNN xs) = neighborDistance $ last xs

knn_cata :: (SingI k, MetricSpace dp, Eq dp) => dp -> dp -> KNN k dp -> KNN k dp
knn_cata query next current = if next==query
    then current
    else KNN [Neighbor next $ distance query next] <> current

interleave :: (Eq a, Ord (Ring a)) => [Neighbor a] -> [Neighbor a] -> [Neighbor a]
interleave xs [] = xs
interleave [] ys = ys
interleave (x:xs) (y:ys) = case compare x y of
    LT -> x:(interleave xs (y:ys))
    GT -> y:(interleave (x:xs) ys)
    EQ -> if neighbor x == neighbor y
        then x:interleave xs ys
        else x:y:interleave xs ys

-- property_sorts :: [Double] -> [Double] -> Bool
property_sorts xs ys = go $ interleave xs' ys'
    where
        xs' = sort xs
        ys' = sort ys

        go [] = True
        go (x:[]) = True
        go (x1:x2:xs) = if x1<x2
            then go (x2:xs)
            else False

---------------------------------------

knn2_single :: (SingI k, SpaceTree t dp, Eq dp, F.Foldable t, Ord dp) => DualTree (t dp) -> KNN2 k dp
knn2_single dual = F.foldMap (\dp -> KNN2 $ Map.singleton dp $ knn dp $ reference dual) (query dual)

knn2_single_slow :: (SingI k, SpaceTree t dp, Eq dp, F.Foldable t, Ord dp) => DualTree (t dp) -> KNN2 k dp
knn2_single_slow dual = F.foldMap (\dp -> KNN2 $ Map.singleton dp $ knn_slow dp $ reference dual) (query dual)

knn2_parallel :: 
    ( SingI k
    , SpaceTree t dp
    , Eq dp, F.Foldable t, Ord dp
    , NFData (Ring dp), NFData dp
    ) => DualTree (t dp) -> KNN2 k dp
knn2_parallel dual = (parallel reduce) $ map (\dp -> KNN2 $ Map.singleton dp $ knn dp $ reference dual) (F.toList $ query dual)

