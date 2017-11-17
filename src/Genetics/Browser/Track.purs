module Genetics.Browser.Track where

import Prelude

import Control.Monad.Aff (Aff)
import Control.Monad.Aff.AVar (AVar, makeVar, takeVar)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Rec.Class (forever)
import Control.Monad.State (StateT(..))
import Control.Monad.State as State
import Control.Monad.Trans.Class (lift)
import Data.Foldable (for_)
import Data.Maybe (Maybe(..))
import Data.Traversable (traverse_)
import Data.Tuple (Tuple(..))
import Genetics.Browser.DataSource (DataSource)
import Genetics.Browser.Glyph (Glyph, circle)
import Genetics.Browser.GlyphF.Canvas (renderGlyph)
import Genetics.Browser.Types (Bp(..), BpPerPixel(..), Chr, ChrId(..), Point, Range, bpToPixels)
import Genetics.Browser.UI.Native (getScreenSize)
import Genetics.Browser.UI.Native.View as View
import Genetics.Browser.View (View, Pixels)
import Graphics.Canvas (CanvasElement, Context2D, getCanvasHeight, getContext2D, setCanvasWidth)
import Graphics.Canvas as C


type Track aff eff a = { source :: DataSource aff a
                       , render :: Array a -> Eff eff Unit
                       , getPoint :: Point -> Array a
                       , chrSize :: Chr -> Bp
                       }

{-

Have a way to "prepare" data per-chromosome for rendering.

Then have a way to actually render that prepared data,
given some extra information such as offset, height scaling, etc.



Also need to map clicks backward, but that should be doable.



Maybe render to an offscreen canvas and copyImage.
Not sure that makes sense either
-}



-- given a size on the chromosome,
-- the position of the chromosome,
-- return a function from scale to ncanvas X-coordinate
type XPosInfo = { size :: Bp, scale :: BpPerPixel }

posPixelsX :: XPosInfo
           -> Bp
           -> Pixels
posPixelsX { scale } pos = bpToPixels scale pos



-- given a position relative to the track where 0.0 = bottom, 1.0 = top,
-- information about where the track will be drawn and how,
-- return the canvas Y-coordinate
type YPosInfo = { offset :: Pixels, height :: Pixels }

posPixelsY :: YPosInfo
           -> Number
           -> Pixels
posPixelsY { offset, height } rel = height - (rel * height + offset)




-- Given a score range,
-- size of the current chr + scale (scale should be somewhere else...)
-- vertical size of the track
-- we can produce a mapping from canvases to SingleGlyph renderers



{- note:
  check purescript-drawings out.

wait, aren't these basically the same

(         a -> (Translation, Eff _ Unit))
(Identity a -> (Translation, Eff _ Unit))

(       f a ->  g           (Eff _ Unit))
(       f a ->  Identity    (Eff _ Unit))
-}




-- Commands the renderer thread can receive
data RenderCmds a =
    Render (Array { chrId :: ChrId, features :: Array a})
  | SetView View
  | Scroll Pixels




type RenderBackend = { canvas :: CanvasElement
                     , backCanvas :: CanvasElement
                     }
{-
renderer :: forall eff a.
            RenderBackend
         -> Renderer eff a
         -> AVar (RenderCmds a)
         -> StateT View (Aff _) Unit
renderer cvs r cmdVar = forever do
  cmd <- lift $ takeVar cmdVar
  case cmd of
    Render fs -> do
      -- let toRender :: Array (RenderParams -> Eff _ Unit)
      --     toRender = map r fs
      -- Use current (or provided?) View to derive RenderParams for each
      pure unit

    Scroll n -> do
      pure unit

    SetView v -> do
      State.put v
      pure unit
-}


testFetch :: String
          -> Aff _ (Array { score :: Number, pos :: Bp })
testFetch url = do
  json <- _.response <$> Affjax.get url

  let f :: Json -> Maybe {score :: Number, pos :: Bp}
      f j = do
            obj <- j ^? _Object
            pos <- Bp <$> obj ^? ix "min" <<< _Number
            pValue <- readFloat <$> obj ^? ix "pValue" <<< _String
            let score = (-1.0) * (Math.log pValue / Math.log 10.0)
            pure {pos, score}

  case traverse f =<< json ^? _Array of
    Nothing -> throwError $ error "Failed to parse JSON features"
    Just fs -> pure $ fs





testRender :: forall a.
              Renderer _ a
           -> Array a
           -> Aff _ Unit
testRender r as = do
  liftEff $ log "running"
  canvas <- liftEff $ unsafePartial $ fromJust <$> getCanvasElementById "canvas"
  ctx <- liftEff $ getContext2D canvas

  {w,h} <- liftEff do
    {w} <- getScreenSize
    h <- getCanvasHeight canvas
    _ <- setCanvasWidth (w-2.0) canvas
    pure {w, h}

  let size = Bp 122030190.0
      n = 10
      scale = BpPerPixel (unwrap size / (w / 10.0))
      xInfo = { size, scale }
      height = h
      offset = 0.0
      yInfo = { height, offset }
      colors = Tuple <$> ["yellow", "orange", "red", "purple", "blue"]

      fs :: Frames (Array _)
      fs = frames w 20.0 (const size) (Array.replicate 5 as)

      fs' :: Frames (Tuple String (Array _))
      fs' = zipWithFrames colors fs

      r' :: Renderer _ (Tuple String a)
      r' = strokeRenderer r


  liftEff $ renderFramesN yInfo fs r ctx



main = launchAff $ do
  dat <- testFetch "./gwas.json"
  let min = 0.0
      max = 50.0
  testRender (gwasRenderer {min, max}) dat



{-
trackEvents :: _
trackEvents = viewB
  where cDrag = canvasDrag canvas
        lefts = case _ of
          Left x -> Just x
          Right _ -> Nothing
        -- the alt operator <|> combines the two event streams,
        -- resulting in an event of both button-click scrolls
        -- and canvas-drag scrolls

        dragScroll = filterMap (map (ScrollPixels <<< _.x) <<< lefts) cDrag
        updateViews = btnScroll (Bp 500.0)
                  <|> dragScroll
                  <|> btnZoom (wrap <<< (_ * 0.8) <<< unwrap)
                              (wrap <<< (_ * 1.2) <<< unwrap)
                  <|> scrollZoom canvas
        viewB = FRP.fold foldView updateViews v
-}


-- a `Track` is the more or less abstract representation of the track;
-- it needs to be run to do anything.

-- TODO it also needs to be able to receive messages and send messages

-- runTrack :: forall a r.
--             View
--          -> Track _ _ a
--          -> Aff _ Unit
-- runTrack opts { source, render, getPoint, chrSize } = do
  -- ctx <- liftEff $ getContext2D opts.canvas

  -- {w,h} <- liftEff do
  --   {w} <- getScreenSize
  --   h <- getCanvasHeight opts.canvas
  --   _ <- setCanvasWidth (w-2.0) opts.canvas
  --   pure {w, h}

  -- trackState <- makeVar

  -- -- TODO handle resize
  -- let v = View.fromCanvasWidth chrSize opts

  -- feats <- fetch
  -- pure unit

{-

browser :: Aff _ Unit
browser uri = do
  canvas <- liftEff $ unsafePartial $ fromJust <$> getCanvasElementById "canvas"
  ctx <- liftEff $ getContext2D canvas

  {w,h} <- liftEff do
    {w} <- getScreenSize
    h <- getCanvasHeight canvas
    _ <- setCanvasWidth (w-2.0) canvas
    pure {w, h}

  backCanvas <- liftEff $ newCanvas {w,h}
  browserState <- makeVar

  let minView = Bp 0.0
      maxView = Bp 15000000.0
      v = View.fromCanvasWidth w { min: minView, max: maxView }
      f :: View -> Fetch _
      f = fileFetch uri

  fs <- f v


  let renderer :: View -> Array _ -> _
      renderer = renderGlyphs (browserTransform h) ctx
      fetch :: View -> Aff _ _
      fetch v = do

        let gs = glyphifyFeatures fs v
            annGs = zip fs gs
        let gs' = filterFeatures v annGs

        putVar browserState { annotatedGlyphs: annGs
                            , view: v }
        liftEff do
          clearCanvas canvas
          renderer v gs'


  let cDrag = canvasDrag canvas
      lefts = case _ of
        Left x -> Just x
        Right _ -> Nothing
      -- the alt operator <|> combines the two event streams,
      -- resulting in an event of both button-click scrolls
      -- and canvas-drag scrolls

      dragScroll = filterMap (map (ScrollPixels <<< _.x) <<< lefts) cDrag
      updateViews = btnScroll (Bp 500.0)
                <|> dragScroll
                <|> btnZoom (wrap <<< (_ * 0.8) <<< unwrap)
                            (wrap <<< (_ * 1.2) <<< unwrap)
                <|> scrollZoom canvas
      viewB = FRP.fold foldView updateViews v


  _ <- liftEff $ unsafeCoerceEff $ FRP.subscribe cDrag $ case _ of
    Left _      -> pure unit
    Right {x,y} -> scrollCanvas backCanvas canvas {x: -x, y: 0.0}


  _ <- liftEff $ unsafeCoerceEff $ FRP.subscribe viewB \v' -> do
    _ <- launchAff $ fetch v'

  fetch v
  -}