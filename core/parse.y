// BUILD file parser.

// This is a yacc grammar. Its lexer is in lex.go.
//
// For a good introduction to writing yacc grammars, see
// Kernighan and Pike's book The Unix Programming Environment.
//
// The definitive yacc manual is
// Stephen C. Johnson and Ravi Sethi, "Yacc: A Parser Generator",
// online at http://plan9.bell-labs.com/sys/doc/yacc.pdf.

%{
package build
%}

// The generated parser puts these fields in a struct named yySymType.
// (The name %union is historical, but it is inaccurate for Go.)
%union {
	// input tokens
	tok       string     // raw input syntax
	str       string     // decoding of quoted string
	pos       Position   // position of token
	triple    bool       // was string triple quoted?

	// partial syntax trees
	expr      Expr
	exprs     []Expr
	forc      *ForClause
	fors      []*ForClause
	ifs       []*IfClause
	string    *StringExpr
	strings   []*StringExpr

	// supporting information
	comma     Position   // position of trailing comma in list, if present
	lastRule  Expr  // most recent rule, to attach line comments to
}

// These declarations set the type for a $ reference ($$, $1, $2, ...)
// based on the kind of symbol it refers to. Other fields can be referred
// to explicitly, as in $<tok>1.
//
// %token is for input tokens generated by the lexer.
// %type is for higher-level grammar rules defined here.
//
// It is possible to put multiple tokens per line, but it is easier to
// keep ordered using a sparser one-per-line list.

%token	<pos>	'%'
%token	<pos>	'('
%token	<pos>	')'
%token	<pos>	'*'
%token	<pos>	'+'
%token	<pos>	','
%token	<pos>	'-'
%token	<pos>	'.'
%token	<pos>	'/'
%token	<pos>	':'
%token	<pos>	'<'
%token	<pos>	'='
%token	<pos>	'>'
%token	<pos>	'['
%token	<pos>	']'
%token	<pos>	'{'
%token	<pos>	'}'

// By convention, yacc token names are all caps.
// However, we do not want to export them from the Go package
// we are creating, so prefix them all with underscores.

%token	<pos>	_ADDEQ   // operator +=
%token	<pos>	_AND     // keyword and
%token	<pos>	_COMMENT // top-level # comment
%token	<pos>	_EOF     // end of file
%token	<pos>	_EQ      // operator ==
%token	<pos>	_FOR     // keyword for
%token	<pos>	_GE      // operator >=
%token	<pos>	_IDENT   // non-keyword identifier or number
%token	<pos>	_IF      // keyword if
%token	<pos>	_ELSE    // keyword else
%token	<pos>	_IN      // keyword in
%token	<pos>	_IS      // keyword is
%token	<pos>	_LAMBDA  // keyword lambda
%token	<pos>	_LE      // operator <=
%token	<pos>	_NE      // operator !=
%token	<pos>	_NOT     // keyword not
%token	<pos>	_OR      // keyword or
%token	<pos>	_PYTHON  // uninterpreted Python block
%token	<pos>	_STRING  // quoted string

%type	<pos>		comma_opt
%type	<expr>		expr
%type	<expr>		expr_opt
%type	<exprs>		exprs
%type	<exprs>		exprs_opt
%type	<forc>		for_clause
%type	<fors>		for_clauses
%type	<expr>		ident
%type	<exprs>		idents
%type	<ifs>		if_clauses_opt
%type	<exprs>		stmts
%type	<expr>		stmt
%type	<expr>		keyvalue
%type	<exprs>		keyvalues
%type	<exprs>		keyvalues_opt
%type	<string>	string
%type	<strings>	strings

// Operator precedence.
// Operators listed lower in the table bind tighter.

// We tag rules with this fake, low precedence to indicate
// that when the rule is involved in a shift/reduce
// conflict, we prefer that the parser shift (try for a longer parse).
// Shifting is the default resolution anyway, but stating it explicitly
// silences yacc's warning for that specific case.
%left	ShiftInstead

%left	'\n'
%left	_ASSERT
// 'if' and 'else' have lower precedence than all other operators.
// e.g. "a, b if c > 0 else 'foo'" is either a tuple of (a,b) or 'foo'
// and not a tuple of "(a, (b if ... ))"
%left	'=' _ADDEQ
%left   _IF _ELSE
%left	','
%left	':'
%left	_IN _NOT _IS
%left	_OR
%left	_AND
%left	'<' '>' _EQ _NE _LE _GE
%left	'+' '-'
%left	'*' '/' '%'
%left	'.' '[' '('
%right  _UNARY
%left	_STRING

%%

// Grammar rules.
//
// A note on names: if foo is a rule, then foos is a sequence of foos
// (with interleaved commas or other syntax as appropriate)
// and foo_opt is an optional foo.

file:
	stmts _EOF
	{
		yylex.(*input).file = &File{Stmt: $1}
		return 0
	}

stmts:
	{
		$$ = nil
		$<lastRule>$ = nil
	}
|	stmts stmt comma_opt semi_opt
	{
		// If this statement follows a comment block,
		// attach the comments to the statement.
		if cb, ok := $<lastRule>1.(*CommentBlock); ok {
			$$ = $1
			$$[len($1)-1] = $2
			$2.Comment().Before = cb.After
			$<lastRule>$ = $2
			break
		}

		// Otherwise add to list.
		$$ = append($1, $2)
		$<lastRule>$ = $2

		// Consider this input:
		//
		//	foo()
		//	# bar
		//	baz()
		//
		// If we've just parsed baz(), the # bar is attached to
		// foo() as an After comment. Make it a Before comment
		// for baz() instead.
		if x := $<lastRule>1; x != nil {
			com := x.Comment()
			$2.Comment().Before = com.After
			com.After = nil
		}
	}
|	stmts '\n'
	{
		// Blank line; sever last rule from future comments.
		$$ = $1
		$<lastRule>$ = nil
	}
|	stmts _COMMENT
	{
		$$ = $1
		$<lastRule>$ = $<lastRule>1
		if $<lastRule>$ == nil {
			cb := &CommentBlock{Start: $2}
			$$ = append($$, cb)
			$<lastRule>$ = cb
		}
		com := $<lastRule>$.Comment()
		com.After = append(com.After, Comment{Start: $2, Token: $<tok>2})
	}

stmt:
	expr %prec ShiftInstead
|	_PYTHON
	{
		$$ = &PythonBlock{Start: $1, Token: $<tok>1}
	}

semi_opt:
|	semi_opt ';'

expr:
	ident
|	strings %prec ShiftInstead
	{
		if len($1) == 1 {
			$$ = $1[0]
			break
		}

		$$ = $1[0]
		for _, x := range $1[1:] {
			_, end := $$.Span()
			$$ = binary($$, end, "+", x)
		}
	}
|	'[' exprs_opt ']'
	{
		$$ = &ListExpr{
			Start: $1,
			List: $2,
			Comma: $<comma>2,
			End: End{Pos: $3},
			ForceMultiLine: forceMultiLine($1, $2, $3),
		}
	}
|	'[' expr for_clauses if_clauses_opt ']'
	{
		exprStart, _ := $2.Span()
		$$ = &ListForExpr{
			Brack: "[]",
			Start: $1,
			X: $2,
			For: $3,
			If: $4,
			End: End{Pos: $5},
			ForceMultiLine: $1.Line != exprStart.Line,
		}
	}
|	'(' expr for_clauses if_clauses_opt ')'
	{
		exprStart, _ := $2.Span()
		$$ = &ListForExpr{
			Brack: "()",
			Start: $1,
			X: $2,
			For: $3,
			If: $4,
			End: End{Pos: $5},
			ForceMultiLine: $1.Line != exprStart.Line,
		}
	}
|	'{' keyvalue for_clauses if_clauses_opt '}'
	{
		exprStart, _ := $2.Span()
		$$ = &ListForExpr{
			Brack: "{}",
			Start: $1,
			X: $2,
			For: $3,
			If: $4,
			End: End{Pos: $5},
			ForceMultiLine: $1.Line != exprStart.Line,
		}
	}
|	'{' keyvalues_opt '}'
	{
		$$ = &DictExpr{
			Start: $1,
			List: $2,
			Comma: $<comma>2,
			End: End{Pos: $3},
			ForceMultiLine: forceMultiLine($1, $2, $3),
		}
	}
|	'(' exprs_opt ')'
	{
		if len($2) == 1 && $<comma>2.Line == 0 {
			// Just a parenthesized expression, not a tuple.
			$$ = &ParenExpr{
				Start: $1,
				X: $2[0],
				End: End{Pos: $3},
				ForceMultiLine: forceMultiLine($1, $2, $3),
			}
		} else {
			$$ = &TupleExpr{
				Start: $1,
				List: $2,
				Comma: $<comma>2,
				End: End{Pos: $3},
				ForceCompact: forceCompact($1, $2, $3),
				ForceMultiLine: forceMultiLine($1, $2, $3),
			}
		}
	}
|	expr '.' _IDENT
	{
		$$ = &DotExpr{
			X: $1,
			Dot: $2,
			NamePos: $3,
			Name: $<tok>3,
		}
	}
|	expr '(' exprs_opt ')'
	{
		$$ = &CallExpr{
			X: $1,
			ListStart: $2,
			List: $3,
			End: End{Pos: $4},
			ForceCompact: forceCompact($2, $3, $4),
			ForceMultiLine: forceMultiLine($2, $3, $4),
		}
	}
|	expr '(' expr for_clauses if_clauses_opt ')'
	{
		$$ = &CallExpr{
			X: $1,
			ListStart: $2,
			List: []Expr{
				&ListForExpr{
					Brack: "",
					Start: $2,
					X: $3,
					For: $4,
					If: $5,
					End: End{Pos: $6},
				},
			},
			End: End{Pos: $6},
		}
	}
|	expr '[' expr ']'
	{
		$$ = &IndexExpr{
			X: $1,
			IndexStart: $2,
			Y: $3,
			End: $4,
		}
	}
|	expr '[' expr_opt ':' expr_opt ']'
	{
		$$ = &SliceExpr{
			X: $1,
			SliceStart: $2,
			Y: $3,
			Colon: $4,
			Z: $5,
			End: $6,
		}
	}
|	_LAMBDA exprs ':' expr
	{
		$$ = &LambdaExpr{
			Lambda: $1,
			Var: $2,
			Colon: $3,
			Expr: $4,
		}
	}
|	'-' expr  %prec _UNARY { $$ = unary($1, $<tok>1, $2) }
|	_NOT expr %prec _UNARY { $$ = unary($1, $<tok>1, $2) }
|	'*' expr  %prec _UNARY { $$ = unary($1, $<tok>1, $2) }
|	expr '*' expr      { $$ = binary($1, $2, $<tok>2, $3) }
|	expr '%' expr      { $$ = binary($1, $2, $<tok>2, $3) }
|	expr '/' expr      { $$ = binary($1, $2, $<tok>2, $3) }
|	expr '+' expr      { $$ = binary($1, $2, $<tok>2, $3) }
|	expr '-' expr      { $$ = binary($1, $2, $<tok>2, $3) }
|	expr '<' expr      { $$ = binary($1, $2, $<tok>2, $3) }
|	expr '>' expr      { $$ = binary($1, $2, $<tok>2, $3) }
|	expr _EQ expr      { $$ = binary($1, $2, $<tok>2, $3) }
|	expr _LE expr      { $$ = binary($1, $2, $<tok>2, $3) }
|	expr _NE expr      { $$ = binary($1, $2, $<tok>2, $3) }
|	expr _GE expr      { $$ = binary($1, $2, $<tok>2, $3) }
|	expr '=' expr      { $$ = binary($1, $2, $<tok>2, $3) }
|	expr _ADDEQ expr   { $$ = binary($1, $2, $<tok>2, $3) }
|	expr _IN expr      { $$ = binary($1, $2, $<tok>2, $3) }
|	expr _NOT _IN expr { $$ = binary($1, $2, "not in", $4) }
|	expr _OR expr      { $$ = binary($1, $2, $<tok>2, $3) }
|	expr _AND expr     { $$ = binary($1, $2, $<tok>2, $3) }
|	expr _IS expr
	{
		if b, ok := $3.(*UnaryExpr); ok && b.Op == "not" {
			$$ = binary($1, $2, "is not", b.X)
		} else {
			$$ = binary($1, $2, $<tok>2, $3)
		}
	}
|       expr _IF expr _ELSE expr
	{
                $$ = &ConditionalExpr{
                        Then: $1,
                        IfStart: $2,
                        Test: $3,
                        ElseStart: $4,
                        Else: $5,
                }
	}

expr_opt:
	{
		$$ = nil
	}
|	expr

// comma_opt is an optional comma. If the comma is present,
// the rule's value is the position of the comma. Otherwise
// the rule's value is the zero position. Tracking this
// lets us distinguish (x) and (x,).
comma_opt:
	{
		$$ = Position{}
	}
|	','

keyvalue:
	expr ':' expr  {
		$$ = &KeyValueExpr{
			Key: $1,
			Colon: $2,
			Value: $3,
		}
	}

keyvalues:
	keyvalue
	{
		$$ = []Expr{$1}
	}
|	keyvalues ',' keyvalue
	{
		$$ = append($1, $3)
	}

keyvalues_opt:
	{
		$$, $<comma>$ = nil, Position{}
	}
|	keyvalues comma_opt
	{
		$$, $<comma>$ = $1, $2
	}

exprs:
	expr
	{
		$$ = []Expr{$1}
	}
|	exprs ',' expr
	{
		$$ = append($1, $3)
	}

exprs_opt:
	{
		$$, $<comma>$ = nil, Position{}
	}
|	exprs comma_opt
	{
		$$, $<comma>$ = $1, $2
	}

string:
	_STRING
	{
		$$ = &StringExpr{
			Start: $1,
			Value: $<str>1,
			TripleQuote: $<triple>1,
			End: $1.add($<tok>1),
			Token: $<tok>1,
		}
	}

strings:
	string
	{
		$$ = []*StringExpr{$1}
	}
|	strings string
	{
		$$ = append($1, $2)
	}

ident:
	_IDENT
	{
		$$ = &LiteralExpr{Start: $1, Token: $<tok>1}
	}

idents:
	ident
	{
		$$ = []Expr{$1}
	}
|	idents ',' ident
	{
		$$ = append($1, $3)
	}

for_clause:
	_FOR idents _IN expr
	{
		$$ = &ForClause{
			For: $1,
			Var: $2,
			In: $3,
			Expr: $4,
		}
	}
|	_FOR '(' idents ')' _IN expr
	{
		$$ = &ForClause{
			For: $1,
			Var: $3,
			In: $5,
			Expr: $6,
		}
	}

for_clauses:
	for_clause
	{
		$$ = []*ForClause{$1}
	}
|	for_clauses for_clause {
		$$ = append($1, $2)
	}

if_clauses_opt:
	{
		$$ = nil
	}
|	if_clauses_opt _IF expr
	{
		$$ = append($1, &IfClause{
			If: $2,
			Cond: $3,
		})
	}

%%

// Go helper code.

// unary returns a unary expression with the given
// position, operator, and subexpression.
func unary(pos Position, op string, x Expr) Expr {
	return &UnaryExpr{
		OpStart: pos,
		Op:      op,
		X:       x,
	}
}

// binary returns a binary expression with the given
// operands, position, and operator.
func binary(x Expr, pos Position, op string, y Expr) Expr {
	_, xend := x.Span()
	ystart, _ := y.Span()
	return &BinaryExpr{
		X:       x,
		OpStart: pos,
		Op:      op,
		LineBreak: xend.Line < ystart.Line,
		Y:       y,
	}
}

// forceCompact returns the setting for the ForceCompact field for a call or tuple.
//
// NOTE 1: The field is called ForceCompact, not ForceSingleLine,
// because it only affects the formatting associated with the call or tuple syntax,
// not the formatting of the arguments. For example:
//
//	call([
//		1,
//		2,
//		3,
//	])
//
// is still a compact call even though it runs on multiple lines.
//
// In contrast the multiline form puts a linebreak after the (.
//
//	call(
//		[
//			1,
//			2,
//			3,
//		],
//	)
//
// NOTE 2: Because of NOTE 1, we cannot use start and end on the
// same line as a signal for compact mode: the formatting of an
// embedded list might move the end to a different line, which would
// then look different on rereading and cause buildifier not to be
// idempotent. Instead, we have to look at properties guaranteed
// to be preserved by the reformatting, namely that the opening
// paren and the first expression are on the same line and that
// each subsequent expression begins on the same line as the last
// one ended (no line breaks after comma).
func forceCompact(start Position, list []Expr, end Position) bool {
	if len(list) <= 1 {
		// The call or tuple will probably be compact anyway; don't force it.
		return false
	}

	// If there are any named arguments or non-string, non-literal
	// arguments, cannot force compact mode.
	line := start.Line
	for _, x := range list {
		start, end := x.Span()
		if start.Line != line {
			return false
		}
		line = end.Line
		switch x.(type) {
		case *LiteralExpr, *StringExpr:
			// ok
		default:
			return false
		}
	}
	return end.Line == line
}

// forceMultiLine returns the setting for the ForceMultiLine field.
func forceMultiLine(start Position, list []Expr, end Position) bool {
	if len(list) > 1 {
		// The call will be multiline anyway, because it has multiple elements. Don't force it.
		return false
	}

	if len(list) == 0 {
		// Empty list: use position of brackets.
		return start.Line != end.Line
	}

	// Single-element list.
	// Check whether opening bracket is on different line than beginning of
	// element, or closing bracket is on different line than end of element.
	elemStart, elemEnd := list[0].Span()
	return start.Line != elemStart.Line || end.Line != elemEnd.Line
}
