{-# OPTIONS_HADDOCK hide #-}

{-# LANGUAGE OverloadedStrings, BangPatterns, RecordWildCards #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Text.XHtml.internals
-- Copyright   :  (c) Andy Gill, and the Oregon Graduate Institute of
--                Science and Technology, 1999-2001,
--                (c) Bjorn Bringert, 2004-2006
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Chris Dornan <chris@chrisdornan.com>
-- Stability   :  Stable
-- Portability :  Portable
--
-- Internals of the XHTML combinator library.
-----------------------------------------------------------------------------
module Text.XHtml.Internals
    ( module Text.XHtml.Internals
    , Builder
    , Seq
    ) where

import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.ByteString.Lazy as BSL
import Data.ByteString.Builder
import Data.Char
import qualified Data.Semigroup as Sem
import qualified Data.Monoid as Mon
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Sequence as Seq
import Data.Sequence (Seq)
import Data.Foldable (toList)

infixr 2 +++  -- combining Html
infixr 7 <<   -- nesting Html
infixl 8 !    -- adding optional arguments

--
-- * Data types
--

-- | A important property of Html is that all strings inside the
-- structure are already in Html friendly format.
data HtmlElement
      = HtmlString !Builder
        -- ^ ..just..plain..normal..text... but using &copy; and &amb;, etc.
      | HtmlTag {
              markupTag      :: !Builder,
              markupAttrs    :: !([HtmlAttr] -> [HtmlAttr]),
              markupContent  :: !Html
              }
        -- ^ tag with internal markup

-- | Attributes with name and value.
data HtmlAttr = HtmlAttr !Builder !Builder


htmlAttrPair :: HtmlAttr -> (Builder,Builder)
htmlAttrPair (HtmlAttr n v) = (n,v)


newtype Html = Html { unHtml :: Seq HtmlElement }

getHtmlElements :: Html -> Seq HtmlElement
getHtmlElements = unHtml

builderToString :: Builder -> String
builderToString =
    Text.unpack . Text.decodeUtf8 . BSL.toStrict . toLazyByteString

--
-- * Classes
--

instance Show Html where
      showsPrec _ html = showString (builderToString (renderHtmlFragment html))
      showList htmls   = foldr (.) id (map shows htmls)

instance Show HtmlAttr where
      showsPrec _ (HtmlAttr str val) =
              showString (builderToString str) .
              showString "=" .
              shows (builderToString val)

-- | @since 3000.2.2
instance Sem.Semigroup Html where
    Html a <> Html b = Html (a <> b)

instance Mon.Monoid Html where
    mempty = noHtml
    mappend = (Sem.<>)

-- | HTML is the class of things that can be validly put
-- inside an HTML tag. So this can be one or more 'Html' elements,
-- or a 'String', for example.
class HTML a where
      toHtml     :: a -> Html
      toHtmlFromList :: [a] -> Html

      toHtmlFromList xs = Html (foldr (\x acc -> unHtml (toHtml x) <> acc) mempty xs)

instance HTML Html where
      toHtml a    = a

instance HTML Char where
      toHtml       a = toHtml [a]
      toHtmlFromList []  = Html mempty
      toHtmlFromList str = Html (pure (HtmlString (stringToHtmlString str)))

instance (HTML a) => HTML [a] where
      toHtml xs = toHtmlFromList xs

instance (HTML a) => HTML (Seq a) where
    toHtml xs = toHtmlFromList (toList xs)

instance HTML a => HTML (Maybe a) where
      toHtml = maybe noHtml toHtml

instance HTML Text where
    toHtml "" = Html mempty
    toHtml xs = Html (pure (HtmlString (textToHtmlString xs)))

mapDlist :: (a -> b) -> ([a] -> [a]) -> [b] -> [b]
mapDlist f as = (map f (as []) ++)

class ADDATTRS a where
      (!) :: a -> [HtmlAttr] -> a

-- | CHANGEATTRS is a more expressive alternative to ADDATTRS
class CHANGEATTRS a where
      changeAttrs :: a -> ([HtmlAttr] -> [HtmlAttr]) -> a

instance (ADDATTRS b) => ADDATTRS (a -> b) where
      fn ! attr        = \ arg -> fn arg ! attr

instance (CHANGEATTRS b) => CHANGEATTRS (a -> b) where
      changeAttrs fn f = \ arg -> changeAttrs (fn arg) f

instance ADDATTRS Html where
    (Html htmls) ! attr = Html (fmap addAttrs htmls)
      where
        addAttrs html =
            case html of
                HtmlTag { markupAttrs = attrs, .. } ->
                    HtmlTag
                        { markupAttrs = attrs . (++ attr)
                        , ..
                        }
                _ ->
                    html


instance CHANGEATTRS Html where
      changeAttrs (Html htmls) f = Html (fmap addAttrs htmls)
        where
              addAttrs (html@(HtmlTag { markupAttrs = attrs }) )
                            = html { markupAttrs = (f . attrs) }
              addAttrs html = html


--
-- * Html primitives and basic combinators
--

-- | Put something inside an HTML element.
(<<) :: (HTML a) =>
        (Html -> b) -- ^ Parent
     -> a -- ^ Child
     -> b
fn << arg = fn (toHtml arg)


concatHtml :: (HTML a) => [a] -> Html
concatHtml = Html . foldMap (unHtml . toHtml)

-- | Create a piece of HTML which is the concatenation
--   of two things which can be made into HTML.
(+++) :: (HTML a, HTML b) => a -> b -> Html
a +++ b = toHtml a <> toHtml b


-- | An empty piece of HTML.
noHtml :: Html
noHtml = Html mempty

-- | Checks whether the given piece of HTML is empty. This materializes the
-- list, so it's not great to do this a bunch.
isNoHtml :: Html -> Bool
isNoHtml (Html xs) = Seq.null xs

-- | Constructs an element with a custom name.
tag :: Builder -- ^ Element name
    -> Html -- ^ Element contents
    -> Html
tag str htmls =
    Html $
        pure HtmlTag
            { markupTag = str
            , markupAttrs = id
            , markupContent = htmls
            }

-- | Constructs an element with a custom name, and
--   without any children.
itag :: Builder -> Html
itag str = tag str noHtml

emptyAttr :: Builder -> HtmlAttr
emptyAttr s = HtmlAttr s s

intAttr :: Builder -> Int -> HtmlAttr
intAttr s i = HtmlAttr s (intDec i)

strAttr :: Builder -> String -> HtmlAttr
strAttr s t = HtmlAttr s (stringToHtmlString t)

htmlAttr :: Builder -> Html -> HtmlAttr
htmlAttr s t = HtmlAttr s (renderHtmlFragment t)


{-
foldHtml :: (String -> [HtmlAttr] -> [a] -> a)
      -> (String -> a)
      -> Html
      -> a
foldHtml f g (HtmlTag str attr fmls)
      = f str attr (map (foldHtml f g) fmls)
foldHtml f g (HtmlString  str)
      = g str

-}

-- | Processing Strings into Html friendly things.
stringToHtmlString :: String -> Builder
stringToHtmlString = foldMap fixChar

fixChar :: Char -> Builder
fixChar '<' = "&lt;"
fixChar '>' = "&gt;"
fixChar '&' = "&amp;"
fixChar '"' = "&quot;"
fixChar c | ord c < 0x80 = charUtf8 c
fixChar c = mconcat ["&#", intDec (ord c), charUtf8 ';']

textToHtmlString :: Text -> Builder
textToHtmlString = Text.foldr (\c acc -> fixChar c <> acc) mempty

-- | This is not processed for special chars.
-- use stringToHtml or lineToHtml instead, for user strings,
-- because they understand special chars, like @'<'@.
primHtml :: String -> Html
primHtml x | null x    = Html mempty
           | otherwise = Html (pure (HtmlString (stringUtf8 x)))

-- | Does not process special characters, or check to see if it is empty.
primHtmlNonEmptyBuilder :: Builder -> Html
primHtmlNonEmptyBuilder x = Html (pure $ HtmlString x)


--
-- * Html Rendering
--

mkHtml :: HTML html => html -> Html
mkHtml = (tag "html" ! [strAttr "xmlns" "http://www.w3.org/1999/xhtml"] <<)

-- | Output the HTML without adding newlines or spaces within the markup.
--   This should be the most time and space efficient way to
--   render HTML, though the output is quite unreadable.
showHtmlInternal :: HTML html =>
                    Builder -- ^ DOCTYPE declaration
                 -> html -> Builder
showHtmlInternal docType theHtml =
    docType <> showHtmlFragment (mkHtml theHtml)

-- | Outputs indented HTML. Because space matters in
--   HTML, the output is quite messy.
renderHtmlInternal :: HTML html =>
                      Builder  -- ^ DOCTYPE declaration
                   -> html -> Builder
renderHtmlInternal docType theHtml =
      docType <> "\n" <> renderHtmlFragment (mkHtml theHtml) <> "\n"

-- | Outputs indented HTML, with indentation inside elements.
--   This can change the meaning of the HTML document, and
--   is mostly useful for debugging the HTML output.
--   The implementation is inefficient, and you are normally
--   better off using 'showHtml' or 'renderHtml'.
prettyHtmlInternal :: HTML html =>
                      String -- ^ DOCTYPE declaration
                   -> html -> String
prettyHtmlInternal docType theHtml =
    docType ++ "\n" ++ prettyHtmlFragment (mkHtml theHtml)

-- | Render a piece of HTML without adding a DOCTYPE declaration
--   or root element. Does not add any extra whitespace.
showHtmlFragment :: HTML html => html -> Builder
showHtmlFragment h =
    foldMap showHtml' $ getHtmlElements $ toHtml h

-- | Render a piece of indented HTML without adding a DOCTYPE declaration
--   or root element. Only adds whitespace where it does not change
--   the meaning of the document.
renderHtmlFragment :: HTML html => html -> Builder
renderHtmlFragment h =
    foldMap (renderHtml' 0) $ getHtmlElements $ toHtml h

-- | Render a piece of indented HTML without adding a DOCTYPE declaration
--   or a root element.
--   The indentation is done inside elements.
--   This can change the meaning of the HTML document, and
--   is mostly useful for debugging the HTML output.
--   The implementation is inefficient, and you are normally
--   better off using 'showHtmlFragment' or 'renderHtmlFragment'.
prettyHtmlFragment :: HTML html => html -> String
prettyHtmlFragment =
    unlines . toList . foldMap prettyHtml' . getHtmlElements . toHtml

-- | Show a single HTML element, without adding whitespace.
showHtml' :: HtmlElement -> Builder
showHtml' (HtmlString str) = str
showHtml'(HtmlTag { markupTag = name,
                    markupContent = html,
                    markupAttrs = attrs })
    = if isValidHtmlITag name && isNoHtml html
      then renderTag True name (attrs []) ""
      else mconcat
        [ renderTag False name (attrs []) ""
        , foldMap showHtml' (getHtmlElements html)
        , renderEndTag name ""
        ]

renderHtml' :: Int -> HtmlElement -> Builder
renderHtml' _ (HtmlString str) = str
renderHtml' n (HtmlTag
              { markupTag = name,
                markupContent = html,
                markupAttrs = attrs })
      = if isValidHtmlITag name && isNoHtml html
        then renderTag True name (attrs []) (nl n)
        else renderTag False name (attrs []) (nl n)
          <> foldMap (renderHtml' (n+2)) (getHtmlElements html)
          <> renderEndTag name (nl n)
    where
      nl n' = "\n" <> Sem.stimes (n' `div` 8) (charUtf8 '\t')
              <> Sem.stimes (n' `mod` 8) (charUtf8 ' ')


prettyHtml' :: HtmlElement -> [String]
prettyHtml' (HtmlString str) = [builderToString str]
prettyHtml' (HtmlTag
              { markupTag = name,
                markupContent = html,
                markupAttrs = attrs })
      = if isValidHtmlITag name && isNoHtml html
        then
         [rmNL (renderTag True name (attrs []) "")]
        else
         [rmNL (renderTag False name (attrs []) "")] ++
          shift (foldMap prettyHtml' (getHtmlElements html)) ++
         [rmNL (renderEndTag name "")]
  where
      shift = map (\x -> "   " ++ x)
      rmNL = filter (/= '\n') . builderToString


-- | Show a start tag
renderTag :: Bool       -- ^ 'True' if the empty tag shorthand should be used
          -> Builder     -- ^ Tag name
          -> [HtmlAttr] -- ^ Attributes
          -> Builder     -- ^ Whitespace to add after attributes
          -> Builder
renderTag empty name attrs nl
      = "<" <> name <> shownAttrs <> nl <> close
  where
      close = if empty then " />" else ">"

      shownAttrs = foldMap (\attr -> charUtf8 ' ' <> showPair attr) attrs

      showPair :: HtmlAttr -> Builder
      showPair (HtmlAttr key val)
              = key <> "=\"" <> val  <> "\""

-- | Show an end tag
renderEndTag :: Builder -- ^ Tag name
             -> Builder -- ^ Whitespace to add after tag name
             -> Builder
renderEndTag name nl = "</" <> name <> nl <> ">"

isValidHtmlITag :: Builder -> Bool
isValidHtmlITag bldr = toLazyByteString bldr `Set.member` validHtmlITags

-- | The names of all elements which can represented using the empty tag
--   short-hand.
validHtmlITags :: Set BSL.ByteString
validHtmlITags = Set.fromList [
                  "area",
                  "base",
                  "basefont",
                  "br",
                  "col",
                  "frame",
                  "hr",
                  "img",
                  "input",
                  "isindex",
                  "link",
                  "meta",
                  "param"
                 ]
