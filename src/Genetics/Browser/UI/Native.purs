module Genetics.Browser.UI.Native where

import Prelude

import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Console (log)
import Control.Monad.Eff.Random (random, randomRange)
import Control.Monad.Eff.Ref (Ref, modifyRef, newRef, readRef, writeRef)
import Control.Monad.Rec.Class (forever)
import DOM (DOM)
import DOM.HTML.HTMLElement (getBoundingClientRect)
import DOM.HTML.Types (HTMLButtonElement, HTMLCanvasElement, HTMLElement)
import Data.Array (range, zip, zipWith, (..))
import Data.Int (round, toNumber)
import Data.Maybe (fromJust)
import Data.Newtype (unwrap, wrap)
import Data.Traversable (sequence, traverse, traverse_)
import Data.Tuple (Tuple(..))
import FRP.Behavior (Behavior, behavior, step)
import FRP.Behavior as FRP
import FRP.Event (Event, subscribe)
import Genetics.Browser.Feature (Feature(..))
import Genetics.Browser.Glyph (Glyph, line, path, stroke)
import Genetics.Browser.GlyphF.Canvas (renderGlyph)
import Genetics.Browser.Units (Bp(..), Chr(..))
import Graphics.Canvas (CanvasElement, Context2D, getCanvasElementById, getCanvasHeight, getCanvasWidth, getContext2D, setCanvasHeight, setCanvasWidth)
import Partial.Unsafe (unsafePartial)
import Unsafe.Coerce (unsafeCoerce)


type Point = { x :: Number
             , y :: Number }

type Fetch eff = Eff eff (Array (Feature Bp Number))


genF :: String -> Bp -> Bp -> Eff _ (Feature Bp Number)
genF chr' min max = do
  let chr = Chr chr'
  score <- randomRange 5.0 10.0
  pure $ Feature chr min max score

toF :: Int -> Number
toF = toNumber

randomFetch :: Int -> Chr -> Number -> Number -> Fetch _
randomFetch n chr min max = do
  let d = (max - min) / toNumber n
      bins = toNumber <$> 0 .. n
      rs = map (\x -> Tuple (x*d) (x*d+d)) bins

  traverse (\ (Tuple a b) -> genF "chr11" (Bp a) (Bp b)) rs


glyphify :: Feature Bp Number
         -> Glyph Unit
glyphify (Feature chr (Bp min) (Bp max) score) = do
  let height = 30.0
      color  = "red"
      midX   = min + ((max - min) / 2.0)
  stroke color
  path [{x: min, y: score}, {x:midX, y: score+height}, {x: max, y: score}]


visible :: View -> Bp -> Boolean
visible v x = v.min > x && x < v.max

hToScreen :: View -> Bp -> Number
hToScreen v x = unwrap $ v.min + (offset / (v.max - v.min))
  where offset = x - v.min

glyphifyWithView :: View
                 -> Feature Bp Number
                 -> Glyph Unit
glyphifyWithView v (Feature chr min' max' score) = do
  when (not visible v min' && not visible v max') $ pure unit

  let height = 30.0
      color  = "red"
      min    = hToScreen v min'
      max    = hToScreen v max'
      midX   = min + ((max - min) / 2.0)
  stroke color
  path [{x: min, y: score}, {x:midX, y: score+height}, {x: max, y: score}]


canvasElementToHTML :: CanvasElement -> HTMLElement
canvasElementToHTML = unsafeCoerce


fetchWithView :: Int -> View -> Fetch _
fetchWithView n v = randomFetch n (Chr "chr11") (unwrap v.min) (unwrap v.max)


fetchToCanvas :: (View -> Fetch _) -> View -> Context2D -> Eff _ Unit
fetchToCanvas f v ctx = do
  features <- f v 
  let gs = traverse_ glyphify features
  renderGlyph ctx gs


foreign import animationFrameLoop :: forall eff.
                                     Eff eff Unit
                                  -> Eff eff Unit

foreign import clearCanvas :: forall eff.
                              Number
                           -> Number
                           -> Context2D
                           -> Eff eff Unit

foreign import setButtonEvent :: forall eff.
                                 String
                              -> Eff eff Unit
                              -> Eff eff Unit

foreign import getScreenSize :: forall eff. Eff eff { w :: Number, h :: Number }


animate :: Number
        -> Number
        -> (View -> Fetch _)
        -> CanvasElement
        -> Ref { prev :: View, cur :: View }
        -> Eff _ Unit
animate w h f canvas vRef = do
  ctx <- getContext2D canvas
  animationFrameLoop do
    v <- readRef vRef
    when (v.cur.min /= v.prev.min ||
          v.cur.max /= v.prev.max) do
        clearCanvas w h ctx
        modifyRef vRef (_ { prev = v.cur })
        fetchToCanvas f v.cur ctx


scrollView :: Bp -> View -> View
scrollView bp v = v { min = v.min + bp, max = v.max + bp }


-- 1st element is a backbuffer, 2nd the one shown on screen
foreign import scrollCanvas :: forall eff.
                               CanvasElement
                            -> CanvasElement
                            -> Point
                            -> Eff eff Unit

-- creates a new CanvasElement, not attached to the DOM and thus not visible
foreign import newCanvas :: forall eff.
                            { w :: Number, h :: Number }
                         -> Eff eff CanvasElement

-- set an event to fire on the given button id
foreign import buttonEvent :: String
                           -> Event Unit

foreign import canvasDragImpl :: CanvasElement -> Event (Nullable Point)

foreign import canvasEvent :: String -> CanvasElement -> Event Point


canvasDrag :: CanvasElement -> Event (Maybe Point)
canvasDrag el = toMaybe <$> canvasDragImpl el


canvasEvents :: CanvasElement
             -> { click :: Event Point
                , mouseup :: Event Point
                , mousedown :: Event Point
                , drag  :: Event (Maybe Point)
                }
canvasEvents el = { click: canvasEvent "click" el
                  , mouseup: canvasEvent "mouseup" el
                  , mousedown: canvasEvent "mousedown" el
                  , drag: canvasDrag el
                  }
-- Given an event of dragging a canvas ending with Nothing,
-- produces an event of the total horizontal dragged distance when mouse is let go
horDragEv :: Event (Maybe Point) -> Event Number
horDragEv ev = ptSum `sampleOn_` doneEv
  where doneEv = filter isNothing ev
        ptSum = FRP.fold (+) (filterMap (map _.x) ev) 0.0


type View = { min :: Bp
            , max :: Bp
            , scale :: BpPerPixel
            }

data UpdateView = ScrollBp Bp
                | ScrollPixels Number
                | SetRange Bp Bp
                | ModScale (BpPerPixel -> BpPerPixel)
                | SetScale BpPerPixel

viewBehavior :: Event UpdateView
             -> View
             -> Event View
viewBehavior ev v = FRP.fold f ev v
  where f :: UpdateView -> View -> View
        f (ScrollBp x) v' = v' { min = v'.min + x
                               , max = v'.max + x }

        f (ScrollPixels x) v' = v' { min = v'.min + (pixelsToBp v'.scale x)
                                   , max = v'.max + (pixelsToBp v'.scale x) }

        f (SetRange min' max') v' = v' { min = min'
                                       , max = max' }

        f (ModScale g) v' = v' { scale = g v'.scale }

        f (SetScale s) v' = v' { scale = s }


-- how far to scroll when clicking a button
btnScroll :: Bp -> Event UpdateView
btnScroll x = f' (-x) <$> buttonEvent "scrollLeft" <|>
              f'   x  <$> buttonEvent "scrollRight"
  where f' = const <<< ScrollBp


-- TODO: set a range to jump the view to
-- TODO: zoom in and out
-- TODO: set zoom/scale
-- TODO: set just one side of the view?

xB :: Behavior Point -> Behavior Number
xB = map (\{x,y} -> x)

scaleViewBehavior :: Number -> Behavior Bp -> Behavior Bp
scaleViewBehavior s b = (wrap <<< (_ * s) <<< unwrap) <$> b
main :: Eff _ Unit
main = do
  mcanvas <- getCanvasElementById "canvas"
  let canvas = unsafePartial (fromJust mcanvas)
  ctx <- getContext2D canvas

  {w,h} <- getScreenSize
  _ <- setCanvasWidth (w-2.0) canvas

  log $ "canvas width: " <> show w

  offset <- getBoundingClientRect $ canvasElementToHTML canvas

  backCanvas <- newCanvas {w,h}

  let minView = Bp 0.0
      maxView = Bp w
      v :: View
      v = { min: minView, max: maxView, scale: BpPerPixel 1.0 }
      f :: View -> Fetch _
      f = fetchWithView 100

  vRef <- newRef { cur: v, prev: v }

  let events = canvasEvents canvas
  let cDrag = canvasDrag canvas
      -- the alt operator <|> combines the two event streams,
      -- resulting in an event of both button-click scrolls
      -- and canvas-drag scrolls
      updateViews = btnScroll (Bp 500.0) <|>
                    (map ScrollPixels <<< horDragEv) cDrag
      viewB = viewBehavior updateViews v

  _ <- FRP.subscribe cDrag $ case _ of
    Nothing -> pure unit
    Just {x,y} -> do
    Just {x,y}  -> scrollCanvas backCanvas canvas {x: -x, y: 0.0}

  _ <- FRP.subscribe viewB \v' -> do
    clearCanvas canvas
    fetchToCanvas f v' ctx



  setButtonEvent "scrollLeft" do
    scrollCanvas backCanvas canvas { x: -100.0, y: 0.0 }
    -- v <- readRef vRef
    -- let newView = scrollView (Bp (-100.0)) v.cur
    -- log $ "scrolling left, to " <> show newView.min
    -- writeRef vRef { cur: newView, prev: v.cur }

  setButtonEvent "scrollRight" do
    scrollCanvas backCanvas canvas { x: -100.0, y: 0.0 }
    -- v <- readRef vRef
    -- let newView = scrollView (Bp 100.0) v.cur
    -- log $ "scrolling right, to " <> show newView.min
    -- writeRef vRef { cur: newView, prev: v.cur }

  -- render first frame
  fetchToCanvas f v ctx
