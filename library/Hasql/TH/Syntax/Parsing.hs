{-|

Our parsing strategy is to port the original Postgres parser as closely as possible.

We're using the @gram.y@ Postgres source file, which is the closest thing we have
to a Postgres syntax spec. Here's a link to it:
https://github.com/postgres/postgres/blob/master/src/backend/parser/gram.y.

Here's the essence of how the original parser is implemented, citing from
[PostgreSQL Wiki](https://wiki.postgresql.org/wiki/Developer_FAQ):

    scan.l defines the lexer, i.e. the algorithm that splits a string
    (containing an SQL statement) into a stream of tokens.
    A token is usually a single word
    (i.e., doesn't contain spaces but is delimited by spaces), 
    but can also be a whole single or double-quoted string for example. 
    The lexer is basically defined in terms of regular expressions 
    which describe the different token types.

    gram.y defines the grammar (the syntactical structure) of SQL statements,
    using the tokens generated by the lexer as basic building blocks.
    The grammar is defined in BNF notation.
    BNF resembles regular expressions but works on the level of tokens, not characters.
    Also, patterns (called rules or productions in BNF) are named, and may be recursive,
    i.e. use themselves as sub-patterns.

-}
module Hasql.TH.Syntax.Parsing where

import Hasql.TH.Prelude hiding (expr, try, option, many, sortBy, filter)
import Text.Megaparsec hiding (some, endBy1, someTill, sepBy1, sepEndBy1)
import Text.Megaparsec.Char
import Control.Applicative.Combinators.NonEmpty
import Hasql.TH.Syntax.Ast
import qualified Text.Megaparsec.Char.Lexer as Lex
import qualified Hasql.TH.Syntax.Predicate as Predicate
import qualified Hasql.TH.Syntax.HashSet as HashSet
import qualified Data.Text as Text
import qualified Text.Builder as TextBuilder


{- $setup
>>> testParser parser = parseTest (parser <* eof)
-}


type Parser = Parsec Void Text


-- * Helpers
-------------------------

filter :: Text -> (a -> Bool) -> Parser a -> Parser a
filter _error _predicate _parser = try $ do
  _result <- _parser
  if _predicate _result
    then return _result
    else fail (Text.unpack _error)

commaSeparator :: Parser ()
commaSeparator = try $ space *> char ',' *> space

dotSeparator :: Parser ()
dotSeparator = try $ space *> char '.' *> space

inParens :: Parser a -> Parser a
inParens p = try $ char '(' *> space *> p <* space <* char ')'

nonEmptyList :: Parser a -> Parser (NonEmpty a)
nonEmptyList p = sepBy1 p commaSeparator

{-|
>>> testParser (quotedString '\'') "'abc''d'"
"abc'd"
-}
quotedString :: Char -> Parser Text
quotedString q = try $ do
  char q
  let
    collectChunks !bdr = do
      chunk <- takeWhileP Nothing (/= q)
      let bdr' = bdr <> TextBuilder.text chunk
      try (consumeEscapedQuote bdr') <|> finish bdr'
    consumeEscapedQuote bdr = do
      char q
      char q
      collectChunks (bdr <> TextBuilder.char q)
    finish bdr = do
      char q
      return (TextBuilder.run bdr)
    in collectChunks mempty

quasiQuote :: Parser a -> Parser a
quasiQuote p = try $ space *> p <* space <* eof


-- * PreparableStmt
-------------------------

preparableStmt :: Parser PreparableStmt
preparableStmt = selectPreparableStmt

selectPreparableStmt :: Parser PreparableStmt
selectPreparableStmt = SelectPreparableStmt <$> selectStmt


-- * Select
-------------------------

selectStmt :: Parser SelectStmt
selectStmt = inParensSelectStmt <|> noParensSelectStmt

inParensSelectStmt :: Parser SelectStmt
inParensSelectStmt = inParens (InParensSelectStmt <$> selectStmt)

noParensSelectStmt :: Parser SelectStmt
noParensSelectStmt = NoParensSelectStmt <$> selectNoParens

selectNoParens :: Parser SelectNoParens
selectNoParens = simpleSelectNoParens

simpleSelectNoParens :: Parser SelectNoParens
simpleSelectNoParens = SimpleSelectNoParens <$> simpleSelect

{-|
>>> test = testParser simpleSelect

>>> test "select"
NormalSimpleSelect Nothing Nothing Nothing Nothing Nothing Nothing Nothing

>>> test "select distinct 1"
...DistinctTargeting Nothing (ExprTarget (LiteralExpr (IntLiteral 1)) Nothing :| [])...

>>> test "select $1"
...NormalTargeting (ExprTarget (PlaceholderExpr 1) Nothing :| [])...

>>> test "select $1 + $2"
...BinOpExpr "+" (PlaceholderExpr 1) (PlaceholderExpr 2)...

>>> test "select a, b"
...ExprTarget (QualifiedNameExpr (SimpleQualifiedName (UnquotedName "a"))) Nothing :| [ExprTarget (QualifiedNameExpr (SimpleQualifiedName (UnquotedName "b"))) Nothing]...

>>> test "select $1 :: text"
...TypecastExpr (PlaceholderExpr 1) (Type "text" False 0 False)...

>>> test "select 1"
...ExprTarget (LiteralExpr (IntLiteral 1))...

>>> test "select id"
...ExprTarget (QualifiedNameExpr (SimpleQualifiedName (UnquotedName "id"))) Nothing...

>>> test "select id from user"
1:20:
  |
1 | select id from user
  |                    ^
Reserved keyword "user" used as an identifier. Wrap it in quotes.
-}
{-
simple_select:
  |  SELECT opt_all_clause opt_target_list
      into_clause from_clause where_clause
      group_clause having_clause window_clause
  |  SELECT distinct_clause target_list
      into_clause from_clause where_clause
      group_clause having_clause window_clause
  |  values_clause
  |  TABLE relation_expr
  |  select_clause UNION all_or_distinct select_clause
  |  select_clause INTERSECT all_or_distinct select_clause
  |  select_clause EXCEPT all_or_distinct select_clause
-}
simpleSelect :: Parser SimpleSelect
simpleSelect = normal where
  normal = try $ do
    string' "select"
    _targeting <- optional (try (space1 *> targeting))
    _intoClause <- optional (try (space1 *> string' "into" *> space1) *> optTempTableName)
    _fromClause <- optional (try (space1 *> string' "from" *> space1) *> nonEmptyList tableRef)
    _whereClause <- optional (try (space1 *> string' "where" *> space1) *> expr)
    _groupClause <- optional (try (space1 *> keyphrase "group by" *> space1) *> nonEmptyList groupByItem)
    _havingClause <- optional (try (space1 *> string' "having" *> space1) *> expr)
    _windowClause <- optional (try (space1 *> string' "window" *> space1) *> nonEmptyList windowDefinition)
    return (NormalSimpleSelect _targeting _intoClause _fromClause _whereClause _groupClause _havingClause _windowClause)

{-
simple_select:
  |  SELECT opt_all_clause opt_target_list
      into_clause from_clause where_clause
      group_clause having_clause window_clause
  |  SELECT distinct_clause target_list
      into_clause from_clause where_clause
      group_clause having_clause window_clause

distinct_clause:
  |  DISTINCT
  |  DISTINCT ON '(' expr_list ')'
-}
targeting :: Parser Targeting
targeting = distinct <|> all <|> normal <?> "targeting" where
  normal = NormalTargeting <$> targetList
  all = try $ do
    string' "all"
    _optTargetList <- optional (try (space1 *> targetList))
    return (AllTargeting _optTargetList)
  distinct = try $ do
    string' "distinct"
    _optOn <- optional (try (space1 *> onExpressionsClause))
    space1
    _targetList <- targetList
    return (DistinctTargeting _optOn _targetList)

targetList :: Parser (NonEmpty Target)
targetList = nonEmptyList target

{-
target_el:
  |  a_expr AS ColLabel
  |  a_expr IDENT
  |  a_expr
  |  '*'
-}
target :: Parser Target
target = allCase <|> exprCase <?> "target" where
  allCase = AllTarget <$ char '*'
  exprCase = try $ do
    _expr <- expr
    _optAlias <- optional $ try $ do
      space1
      try (string' "as" *> space1 *> colLabel) <|> ident
    return (ExprTarget _expr _optAlias)

onExpressionsClause :: Parser (NonEmpty Expr)
onExpressionsClause = try $ do
  string' "on"
  space1
  nonEmptyList expr


-- * Into clause details
-------------------------

optTempTableName :: Parser OptTempTableName
optTempTableName = error "TODO"


-- * Group by details
-------------------------

groupByItem :: Parser GroupByItem
groupByItem = error "TODO"


-- * Window clause details
-------------------------

windowDefinition :: Parser WindowDefinition
windowDefinition = error "TODO"


-- * Table refs
-------------------------

{-
| relation_expr opt_alias_clause
| relation_expr opt_alias_clause tablesample_clause
| func_table func_alias_clause
| LATERAL_P func_table func_alias_clause
| xmltable opt_alias_clause
| LATERAL_P xmltable opt_alias_clause
| select_with_parens opt_alias_clause
| LATERAL_P select_with_parens opt_alias_clause
| joined_table
| '(' joined_table ')' alias_clause

TODO: Add support for joins, inner selects and ctes.
-}
tableRef :: Parser TableRef
tableRef = label "table reference" $ relationExprTableRef

{-
| relation_expr opt_alias_clause
| relation_expr opt_alias_clause tablesample_clause

TODO: Add support for TABLESAMPLE.
-}
relationExprTableRef :: Parser TableRef
relationExprTableRef = try $ do
  _relationExpr <- relationExpr
  _optAliasClause <- optional $ try $ space1 *> aliasClause
  return (RelationExprTableRef _relationExpr _optAliasClause)

{-
| qualified_name
| qualified_name '*'
| ONLY qualified_name
| ONLY '(' qualified_name ')'
-}
relationExpr :: Parser RelationExpr
relationExpr =
  asum
    [
      SimpleRelationExpr <$> qualifiedName <*> pure False,
      try $ SimpleRelationExpr <$> qualifiedName <*> (space1 *> char '*' $> True),
      try $ OnlyRelationExpr <$> (string' "only" *> space1 *> qualifiedName),
      try $ OnlyRelationExpr <$> (string' "only" *> space *> inParens qualifiedName)
    ]

{-
alias_clause:
  |  AS ColId '(' name_list ')'
  |  AS ColId
  |  ColId '(' name_list ')'
  |  ColId
name_list:
  |  name
  |  name_list ',' name
name:
  |  ColId
-}
aliasClause :: Parser AliasClause
aliasClause = try $ do
  _alias <- try (string' "as" *> space1 *> colId) <|> colId
  _columnAliases <- optional $ try $ space1 *> inParens (nonEmptyList colId)
  return (AliasClause _alias _columnAliases)


-- * Expressions
-------------------------

expr :: Parser Expr
expr = loopingExpr <|> nonLoopingExpr

{-|
Expr, which does not start with another expression.
-}
nonLoopingExpr :: Parser Expr
nonLoopingExpr = 
  asum
    [
      placeholderExpr,
      defaultExpr,
      columnRefExpr,
      literalExpr,
      inParensExpr,
      caseExpr,
      funcExpr,
      selectExpr,
      existsSelectExpr,
      arraySelectExpr,
      groupingExpr
    ]

loopingExpr :: Parser Expr
loopingExpr = 
  asum
    [
      typecastExpr,
      escapableBinOpExpr,
      binOpExpr
    ]

placeholderExpr :: Parser Expr
placeholderExpr = try $ PlaceholderExpr <$> (char '$' *> Lex.decimal)

inParensExpr :: Parser Expr
inParensExpr = fmap InParensExpr (inParens expr)

typecastExpr :: Parser Expr
typecastExpr = try $ do
  _a <- nonLoopingExpr
  space
  string "::"
  space
  _type <- type_
  return (TypecastExpr _a _type)

binOpExpr :: Parser Expr
binOpExpr = try $ do
  _a <- nonLoopingExpr
  _binOp <- try (space *> symbolicBinOp <* space) <|> (space1 *> lexicalBinOp <* space1)
  _b <- expr
  return (BinOpExpr _binOp _a _b)

symbolicBinOp :: Parser Text
symbolicBinOp = try $ do
  _text <- takeWhile1P Nothing Predicate.symbolicBinOpChar
  if Predicate.inSet HashSet.symbolicBinOp _text
    then return _text
    else fail ("Unknown binary operator: " <> show _text)

lexicalBinOp :: Parser Text
lexicalBinOp = asum $ fmap keyphrase $ ["and", "or", "is distinct from", "is not distinct from"]

escapableBinOpExpr :: Parser Expr
escapableBinOpExpr = try $ do
  _a <- nonLoopingExpr
  space1
  _not <- option False $ True <$ string' "not" <* space1
  _op <- asum $ fmap (try . keyphrase) $ ["like", "ilike", "similar to"]
  space1
  _b <- expr
  _escaping <- optional $ try $ do
    string' "escape"
    space1
    expr
  return (EscapableBinOpExpr _not _op _a _b _escaping)

defaultExpr :: Parser Expr
defaultExpr = DefaultExpr <$ string' "default"

columnRefExpr :: Parser Expr
columnRefExpr = QualifiedNameExpr <$> columnRef

literalExpr :: Parser Expr
literalExpr = LiteralExpr <$> literal

{-|
Full specification:

>>> testParser caseExpr "CASE WHEN a = b THEN c WHEN d THEN e ELSE f END"
CaseExpr Nothing (WhenClause (BinOpExpr "=" (QualifiedNameExpr (SimpleQualifiedName (UnquotedName "a"))) (QualifiedNameExpr (SimpleQualifiedName (UnquotedName "b")))) (QualifiedNameExpr (SimpleQualifiedName (UnquotedName "c"))) :| [WhenClause (QualifiedNameExpr (SimpleQualifiedName (UnquotedName "d"))) (QualifiedNameExpr (SimpleQualifiedName (UnquotedName "e")))]) (Just (QualifiedNameExpr (SimpleQualifiedName (UnquotedName "f"))))

Implicit argument:

>>> testParser caseExpr "CASE a WHEN b THEN c ELSE d END"
CaseExpr (Just (QualifiedNameExpr (SimpleQualifiedName (UnquotedName "a")))) (WhenClause (QualifiedNameExpr (SimpleQualifiedName (UnquotedName "b"))) (QualifiedNameExpr (SimpleQualifiedName (UnquotedName "c"))) :| []) (Just (QualifiedNameExpr (SimpleQualifiedName (UnquotedName "d"))))
-}
caseExpr :: Parser Expr
caseExpr = label "case expression" $ try $ do
  string' "case"
  space1
  (_arg, _whenClauses) <-
    (Nothing,) <$> sepEndBy1 whenClause space1 <|>
    (,) <$> (Just <$> expr <* space1) <*> sepEndBy1 whenClause space1
  _default <- optional $ try $ do
    string' "else"
    space1
    expr <* space1
  string' "end"
  return $ CaseExpr _arg _whenClauses _default

whenClause :: Parser WhenClause
whenClause = try $ do
  string' "when"
  space1
  _a <- expr
  space1
  string' "then"
  space1
  _b <- expr
  return (WhenClause _a _b)

funcExpr :: Parser Expr
funcExpr = FuncExpr <$> funcApplication

funcApplication :: Parser FuncApplication
funcApplication = try $ do
  _name <- funcName
  space
  _params <- inParens (optional (try funcApplicationParams))
  return (FuncApplication _name _params)

funcApplicationParams :: Parser FuncApplicationParams
funcApplicationParams =
  asum
    [
      normalFuncApplicationParams,
      singleVariadicFuncApplicationParams,
      listVariadicFuncApplicationParams
    ]

normalFuncApplicationParams :: Parser FuncApplicationParams
normalFuncApplicationParams = try $ do
  _optAllOrDistinct <- optional ((string' "all" $> AllAllOrDistinct <|> string' "distinct" $> DistinctAllOrDistinct) <* space1)
  _argList <- nonEmptyList funcArgExpr
  _optSortClause <- optional (space1 *> sortClause)
  return (NormalFuncApplicationParams _optAllOrDistinct _argList _optSortClause)

singleVariadicFuncApplicationParams :: Parser FuncApplicationParams
singleVariadicFuncApplicationParams = try $ do
  string' "variadic"
  space1
  _arg <- funcArgExpr
  _optSortClause <- optional (space1 *> sortClause)
  return (VariadicFuncApplicationParams Nothing _arg _optSortClause)

listVariadicFuncApplicationParams :: Parser FuncApplicationParams
listVariadicFuncApplicationParams = try $ do
  _argList <- nonEmptyList funcArgExpr
  commaSeparator
  string' "variadic"
  space1
  _arg <- funcArgExpr
  _optSortClause <- optional (space1 *> sortClause)
  return (VariadicFuncApplicationParams (Just _argList) _arg _optSortClause)

funcArgExpr :: Parser FuncArgExpr
funcArgExpr = ExprFuncArgExpr <$> expr

sortClause :: Parser (NonEmpty SortBy)
sortClause = try $ do
  keyphrase "order by"
  space1
  nonEmptyList sortBy

sortBy :: Parser SortBy
sortBy = try $ do
  _expr <- expr
  _optOrder <- optional (space1 *> order)
  return (SortBy _expr _optOrder)

order :: Parser Order
order = string' "asc" $> AscOrder <|> string' "desc" $> DescOrder

selectExpr :: Parser Expr
selectExpr = SelectExpr <$> inParens selectNoParens

existsSelectExpr :: Parser Expr
existsSelectExpr = try $ do
  string' "exists"
  space
  ExistsSelectExpr <$> inParens selectNoParens

arraySelectExpr :: Parser Expr
arraySelectExpr = try $ do
  string' "array"
  space
  ExistsSelectExpr <$> inParens selectNoParens

groupingExpr :: Parser Expr
groupingExpr = try $ do
  string' "grouping"
  space
  GroupingExpr <$> inParens (nonEmptyList expr)


-- * Literals
-------------------------

{-|
@
AexprConst: Iconst
      | FCONST
      | Sconst
      | BCONST
      | XCONST
      | func_name Sconst
      | func_name '(' func_arg_list opt_sort_clause ')' Sconst
      | ConstTypename Sconst
      | ConstInterval Sconst opt_interval
      | ConstInterval '(' Iconst ')' Sconst
      | TRUE_P
      | FALSE_P
      | NULL_P
@

>>> testParser literal "- 324098320984320480392480923842"
IntLiteral (-324098320984320480392480923842)

>>> testParser literal "'abc''de'"
StringLiteral "abc'de"

>>> testParser literal "23.43234"
FloatLiteral 23.43234

>>> testParser literal "-32423423.3243248732492739847923874"
FloatLiteral -3.24234233243248732492739847923874e7

>>> testParser literal "NULL"
NullLiteral
-}
literal :: Parser Literal
literal = label "literal" $ asum [numericLiteral, stringLiteral, boolLiteral, nullLiteral]

numericLiteral :: Parser Literal
numericLiteral = label "numeric literal" $ try $ do
  (_input, _scientific) <- match $ Lex.signed space Lex.scientific
  case parseMaybe (Lex.signed space Lex.decimal <* eof :: Parser Integer) _input of
    Just _int -> return (IntLiteral _int)
    Nothing -> return (FloatLiteral _scientific)

stringLiteral :: Parser Literal
stringLiteral = quotedString '\'' <&> StringLiteral <?> "string literal"

boolLiteral :: Parser Literal
boolLiteral = BoolLiteral True <$ string' "true" <|> BoolLiteral False <$ string' "false" <?> "bool literal"

nullLiteral :: Parser Literal
nullLiteral = NullLiteral <$ string' "null" <?> "null literal"


-- * Types
-------------------------

{-|
>>> testParser type_ "int4"
Type "int4" False 0 False

>>> testParser type_ "int4?"
Type "int4" True 0 False

>>> testParser type_ "int4[]"
Type "int4" False 1 False

>>> testParser type_ "int4[ ] []"
Type "int4" False 2 False

>>> testParser type_ "int4[][]?"
Type "int4" False 2 True

>>> testParser type_ "int4?[][]"
Type "int4" True 2 False
-}
type_ :: Parser Type
type_ = try $ do
  _baseName <- fmap Text.toLower $ takeWhile1P Nothing isAlphaNum
  _baseNullable <- option False (try (True <$ space <* char '?'))
  _arrayLevels <- fmap length $ many $ space *> char '[' *> space *> char ']'
  _arrayNullable <- option False (try (True <$ space <* char '?'))
  return (Type _baseName _baseNullable _arrayLevels _arrayNullable)


-- * References & Names
-------------------------

quotedName :: Parser Name
quotedName = label "quoted name" $ try $ do
  _contents <- quotedString '"'
  if Text.null _contents
    then fail "Empty name"
    else return (QuotedName _contents)

ident :: Parser Name
ident = quotedName <|> keywordNameByPredicate (not . Predicate.keyword)

{-
ColId:
  |  IDENT
  |  unreserved_keyword
  |  col_name_keyword
-}
{-# NOINLINE colId #-}
colId :: Parser Name
colId = ident <|> keywordNameFromSet (HashSet.unreservedKeyword <> HashSet.colNameKeyword)

{-
ColLabel:
  |  IDENT
  |  unreserved_keyword
  |  col_name_keyword
  |  type_func_name_keyword
  |  reserved_keyword
-}
colLabel :: Parser Name
colLabel = ident <|> keywordNameFromSet HashSet.keyword

{-
qualified_name:
  | ColId
  | ColId indirection
-}
qualifiedName :: Parser QualifiedName
qualifiedName = simpleQualifiedName <|> indirectedQualifiedName

simpleQualifiedName = SimpleQualifiedName <$> colId

indirectedQualifiedName = try (IndirectedQualifiedName <$> colId <*> (space *> indirection))

{-
columnref:
  | ColId
  | ColId indirection
-}
columnRef = qualifiedName

{-
func_name:
  | type_function_name
  | ColId indirection
type_function_name:
  | IDENT
  | unreserved_keyword
  | type_func_name_keyword
-}
funcName =
  SimpleQualifiedName <$> ident <|>
  SimpleQualifiedName <$> keywordNameFromSet (HashSet.unreservedKeyword <> HashSet.typeFuncNameKeyword) <|>
  indirectedQualifiedName

{-
indirection:
  | indirection_el
  | indirection indirection_el
-}
indirection :: Parser Indirection
indirection = sepBy1 indirectionEl (try space)

{-
indirection_el:
  | '.' attr_name
  | '.' '*'
  | '[' a_expr ']'
  | '[' opt_slice_bound ':' opt_slice_bound ']'
opt_slice_bound:
  | a_expr
  | EMPTY
-}
indirectionEl :: Parser IndirectionEl
indirectionEl = asum [attrNameCase, allCase, exprCase, sliceCase] <?> "indirection element" where
  attrNameCase = try $ AttrNameIndirectionEl <$> (char '.' *> space *> attrName)
  allCase = try $ AllIndirectionEl <$ (char '.' *> space *> char '*')
  exprCase = try $ ExprIndirectionEl <$> (char '[' *> space *> expr <* space <* char ']')
  sliceCase = try $ do
    char '['
    space
    _a <- optional (try expr)
    space
    char ':'
    space
    _b <- optional (try expr)
    space
    char ']'
    return (SliceIndirectionEl _a _b)

{-
attr_name:
  | ColLabel
-}
attrName = colLabel

keywordNameFromSet :: HashSet Text -> Parser Name
keywordNameFromSet _set = keywordNameByPredicate (Predicate.inSet _set)

keywordNameByPredicate :: (Text -> Bool) -> Parser Name
keywordNameByPredicate _predicate = try $ do
  _keyword <- keyword
  if _predicate _keyword
    then return (UnquotedName _keyword)
    else fail ("Reserved keyword " <> show _keyword <> " used as an identifier. Wrap it in quotes.")

keyword :: Parser Text
keyword = label "keyword" $ try $ do
  _firstChar <- satisfy Predicate.firstIdentifierChar
  _remainder <- takeWhileP Nothing Predicate.notFirstIdentifierChar
  return (Text.cons _firstChar _remainder)

{-|
Consume a keyphrase, ignoring case and types of spaces between words.
-}
keyphrase :: Text -> Parser Text
keyphrase a = Text.words a & fmap (void . string') & intersperse space1 & sequence_ & fmap (const a) & try & label ("keyphrase " <> Text.unpack a)
