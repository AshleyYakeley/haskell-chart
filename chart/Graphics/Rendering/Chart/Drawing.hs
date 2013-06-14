{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# OPTIONS_GHC -XTemplateHaskell #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Graphics.Rendering.Chart.Drawing
-- Copyright   :  (c) Tim Docker 2006
-- License     :  BSD-style (see chart/COPYRIGHT)
--
-- This module contains basic types and functions used for drawing.
--
-- Note that template haskell is used to derive accessor functions
-- (see 'Data.Accessor') for each field of the following data types:
--
--    * 'LineStyle'
--
--    * 'FontStyle'
--
-- These accessors are not shown in this API documentation.  They have
-- the same name as the field, but with the trailing underscore
-- dropped. Hence for data field f_::F in type D, they have type
--
-- @
--   f :: Data.Accessor.Accessor D F
-- @
--

module Graphics.Rendering.Chart.Drawing
  ( bStrokePath
  , bFillPath
  , moveTo
  , lineTo
  , defaultColorSeq
  
  , alignFillPath
  , alignStrokePath
  
  , alignp
  , alignc
  
  , bDrawText
  , bDrawTextR
  , drawTextR
  , drawTextsR
    
  , solidLine
  , dashedLine

  , defaultPointStyle
  , filledCircles
  , hollowCircles
  , filledPolygon
  , hollowPolygon
  , plusses
  , exes
  , stars
    
  , solidFillStyle

  , defaultFontStyle
  
  , module Graphics.Rendering.Chart.Types
  , module Graphics.Rendering.Chart.Backend
) where

import Data.Default
import Data.Accessor
import Data.Accessor.Template
import Data.Colour
import Data.Colour.SRGB
import Data.Colour.Names
import Data.List (unfoldr)

import Control.Monad.Reader

import Graphics.Rendering.Chart.Types
import Graphics.Rendering.Chart.Backend
import Graphics.Rendering.Chart.Geometry

-- -----------------------------------------------------------------------
-- Transformation helpers
-- -----------------------------------------------------------------------

-- | Apply a local rotation. The angle is given in radians.
withRotation :: (ChartBackend m) => Double -> m a -> m a
withRotation angle = withTransform (rotate angle 1)

-- | Apply a local translation.
withTranslation :: (ChartBackend m) => Point -> m a -> m a
withTranslation p = withTransform (translate (pointToVec p) 1)

-- -----------------------------------------------------------------------
-- Alignment Helpers
-- -----------------------------------------------------------------------

align :: (Point -> Point) -> PathElement -> PathElement
align f pe = case pe of
  MoveTo p -> MoveTo $ f p
  LineTo p -> LineTo $ f p
  Arc p r a1 a2 -> Arc (f p) r a1 a2
  ArcNeg p r a1 a2 -> ArcNeg (f p) r a1 a2

alignStrokePath :: (ChartBackend m) => Path -> m Path
alignStrokePath p = do
  f <- liftM cbePointAlignFn ask
  return $ toPath $ map (align f) (fromPath p)

alignFillPath :: (ChartBackend m) => Path -> m Path
alignFillPath p = do
  f <- liftM cbeCoordAlignFn ask
  return $ toPath $ map (align f) (fromPath p)

alignp :: (ChartBackend m) => Point -> m Point
alignp p = do 
    alignfn <- liftM cbePointAlignFn ask
    return (alignfn p)

alignc :: (ChartBackend m) => Point -> m Point
alignc p = do 
    alignfn <- liftM cbeCoordAlignFn ask
    return (alignfn p)

-- -----------------------------------------------------------------------
-- Abstract Drawing Methods
-- -----------------------------------------------------------------------

stepPath :: (ChartBackend m) => [Point] -> m ()
stepPath (p:ps) = do
    bNewPath                    
    bMoveTo p
    mapM_ bLineTo ps
stepPath _  = return ()

-- | Draw lines between the specified points.
--
-- The points will be "corrected" by the cenv_point_alignfn, so that
-- when drawing bitmaps, 1 pixel wide lines will be centred on the
-- pixels.
bStrokePath :: (ChartBackend m) => [Point] -> m ()
bStrokePath pts = do
    alignfn <- liftM cbePointAlignFn ask
    stepPath (map alignfn pts)
    bStroke

-- | Fill the region with the given corners.
--
-- The points will be "corrected" by the cenv_coord_alignfn, so that
-- when drawing bitmaps, the edges of the region will fall between
-- pixels.
bFillPath :: (ChartBackend m) => [Point] -> m ()
bFillPath pts = do
    alignfn <- liftM cbeCoordAlignFn ask
    stepPath (map alignfn pts)
    bFill

moveTo :: (ChartBackend m) => Point -> m ()
moveTo p  = do
    p' <- alignp p
    bMoveTo p'
    
lineTo :: (ChartBackend m) => Point -> m ()
lineTo p = do
    p' <- alignp p
    bLineTo p'

bDrawText :: (ChartBackend m) => HTextAnchor -> VTextAnchor -> Point -> String -> m ()
bDrawText hta vta p s = drawTextR hta vta 0 p s

bDrawTextR :: (ChartBackend m) => HTextAnchor -> VTextAnchor -> Double -> Point -> String -> m ()
bDrawTextR hta vta angle p s = drawTextR hta vta angle p s

-- | Function to draw a textual label anchored by one of its corners
--   or edges, with rotation. Rotation angle is given in degrees,
--   rotation is performed around anchor point.
drawTextR :: (ChartBackend m) => HTextAnchor -> VTextAnchor -> Double -> Point -> String -> m ()
drawTextR hta vta angle p s =
  withTranslation p $
    withRotation theta $ do
      ts <- textSize s
      drawText (adjustText hta vta ts) s
  where
    theta = angle*pi/180.0

-- | Function to draw a multi-line textual label anchored by one of its corners
--   or edges, with rotation. Rotation angle is given in degrees,
--   rotation is performed around anchor point.
drawTextsR :: (ChartBackend m) => HTextAnchor -> VTextAnchor -> Double -> Point -> String -> m ()
drawTextsR hta vta angle p s = case num of
      0 -> return ()
      1 -> drawTextR hta vta angle p s
      _ -> do
        withTranslation p $
          withRotation theta $ do
            tss <- mapM textSize ss
            let ts = head tss
            let widths = map textSizeWidth tss
                maxw   = maximum widths
                maxh   = maximum (map textSizeYBearing tss)
                gap    = maxh / 2 -- half-line spacing
                totalHeight = fromIntegral num*maxh +
                              (fromIntegral num-1)*gap
                ys = take num (unfoldr (\y-> Just (y, y-gap-maxh))
                                       (yinit vta ts totalHeight))
                xs = map (adjustTextX hta) tss
            sequence_ (zipWith3 drawT xs ys ss)
    where
      ss   = lines s
      num  = length ss

      drawT x y s = drawText (Point x y) s
      theta = angle*pi/180.0

      yinit VTA_Top      ts height = textSizeAscent ts
      yinit VTA_BaseLine ts height = 0
      yinit VTA_Centre   ts height = height / 2 + textSizeAscent ts
      yinit VTA_Bottom   ts height = height + textSizeAscent ts

adjustText :: HTextAnchor -> VTextAnchor -> TextSize -> Point
adjustText hta vta ts = Point (adjustTextX hta ts) (adjustTextY vta ts)

adjustTextX :: HTextAnchor -> TextSize -> Double
adjustTextX HTA_Left   _  = 0
adjustTextX HTA_Centre ts = (- (textSizeWidth ts / 2))
adjustTextX HTA_Right  ts = (- textSizeWidth ts)

adjustTextY :: VTextAnchor -> TextSize -> Double
adjustTextY VTA_Top      ts = textSizeAscent ts
adjustTextY VTA_Centre   ts = - (textSizeYBearing ts) / 2
adjustTextY VTA_BaseLine _  = 0
adjustTextY VTA_Bottom   ts = -(textSizeDescent ts)

-- -----------------------------------------------------------------------

defaultColorSeq :: [AlphaColour Double]
defaultColorSeq = cycle $ map opaque [blue, red, green, yellow, cyan, magenta]

----------------------------------------------------------------------

solidLine ::
     Double -- ^ Width of line.
  -> AlphaColour Double
  -> LineStyle
solidLine w cl = LineStyle w cl [] LineCapButt LineJoinMiter

dashedLine ::
     Double   -- ^ Width of line.
  -> [Double] -- ^ The dash pattern in device coordinates.
  -> AlphaColour Double
  -> LineStyle
dashedLine w ds cl = LineStyle w cl ds LineCapButt LineJoinMiter

defaultPointStyle :: PointStyle
defaultPointStyle = def

filledCircles :: Double             -- ^ Radius of circle.
              -> AlphaColour Double -- ^ Colour.
              -> PointStyle
filledCircles radius cl = 
  PointStyle cl transparent 0 radius PointShapeCircle

hollowCircles :: Double -- ^ Radius of circle.
              -> Double -- ^ Thickness of line.
              -> AlphaColour Double
              -> PointStyle
hollowCircles radius w cl = 
  PointStyle transparent cl w radius PointShapeCircle

hollowPolygon :: Double -- ^ Radius of circle.
              -> Double -- ^ Thickness of line.
              -> Int    -- ^ Number of vertices.
              -> Bool   -- ^ Is right-side-up?
              -> AlphaColour Double
              -> PointStyle
hollowPolygon radius w sides isrot cl = 
  PointStyle transparent cl w radius (PointShapePolygon sides isrot)

filledPolygon :: Double -- ^ Radius of circle.
              -> Int    -- ^ Number of vertices.
              -> Bool   -- ^ Is right-side-up?
              -> AlphaColour Double
              -> PointStyle
filledPolygon radius sides isrot cl = 
  PointStyle cl transparent 0 radius (PointShapePolygon sides isrot)

plusses :: Double -- ^ Radius of circle.
        -> Double -- ^ Thickness of line.
        -> AlphaColour Double
        -> PointStyle
plusses radius w cl = 
  PointStyle transparent cl w radius PointShapePlus

exes :: Double -- ^ Radius of circle.
     -> Double -- ^ Thickness of line.
     -> AlphaColour Double
     -> PointStyle
exes radius w cl =
  PointStyle transparent cl w radius PointShapeCross

stars :: Double -- ^ Radius of circle.
      -> Double -- ^ Thickness of line.
      -> AlphaColour Double
      -> PointStyle
stars radius w cl =
  PointStyle transparent cl w radius PointShapeStar

solidFillStyle :: AlphaColour Double -> FillStyle
solidFillStyle cl = FillStyleSolid cl

defaultFontStyle :: FontStyle
defaultFontStyle = def

