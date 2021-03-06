module Genetics.Browser.Biodalliance.Types where


import Control.Monad.Eff (kind Effect)
import Data.Foreign (Foreign)
import Genetics.Browser.Types (ChrId)


type View = { viewStart :: Number
            , scale :: Number
            , height :: Number
            , chr :: ChrId
            }


newtype Renderer = Renderer (View -> Array Foreign -> Foreign)


foreign import data Biodalliance :: Type
foreign import data BD :: Effect


type Quant = { min :: Number
             , max :: Number
             }
