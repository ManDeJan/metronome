const bench = @import("bench");
const fun = @import("fun");
const std = @import("std");

const debug = std.debug;
const fmt = std.fmt;
const math = std.math;
const mem = std.mem;

const sscan = fun.scan.sscan;

pub const Token = struct {
    id: Id,
    str: []const u8,

    pub const Id = enum {
        Invalid,
        Identifier,
        Integer,
        LBracket,
        RBracket,
        Star,
        Equal,
        Dot,
        Eos,

        pub fn str(id: Id) []const u8 {
            return switch (id) {
                Id.Invalid => "Invalid",
                Id.Identifier => "Identifier",
                Id.Integer => "Integer",
                Id.LBracket => "[",
                Id.RBracket => "]",
                Id.Star => "*",
                Id.Equal => "=",
                Id.Dot => ".",
                Id.Eos => "Eos",
            };
        }
    };

    pub fn init(id: Id, str: []const u8) Token {
        return Token{
            .id = id,
            .str = str,
        };
    }

    pub fn index(tok: Token, src: []const u8) usize {
        const res = @ptrToInt(tok.str.ptr) - @ptrToInt(src.ptr);
        debug.assert(res <= src.len);
        return res;
    }
};

pub const Tokenizer = struct {
    str: []const u8,
    i: usize,

    pub fn init(str: []const u8) Tokenizer {
        return Tokenizer{
            .str = str,
            .i = 0,
        };
    }

    pub fn rest(tok: Tokenizer) []const u8 {
        return tok.str[tok.i..];
    }

    pub fn next(tok: *Tokenizer) Token {
        const State = enum {
            Begin,
            Identifier,
            Integer,
        };

        var state = State.Begin;
        var start: usize = tok.i;
        while (tok.i < tok.str.len) {
            const c = tok.str[tok.i];
            tok.i += 1;

            switch (state) {
                State.Begin => switch (c) {
                    'a'...'z', 'A'...'Z', '_' => state = State.Identifier,
                    '0'...'9' => state = State.Integer,
                    '[' => return Token.init(Token.Id.LBracket, tok.str[start..tok.i]),
                    ']' => return Token.init(Token.Id.RBracket, tok.str[start..tok.i]),
                    '*' => return Token.init(Token.Id.Star, tok.str[start..tok.i]),
                    '=' => return Token.init(Token.Id.Equal, tok.str[start..tok.i]),
                    '.' => return Token.init(Token.Id.Dot, tok.str[start..tok.i]),
                    else => return Token.init(Token.Id.Invalid, tok.str[start..tok.i]),
                },
                State.Identifier => switch (c) {
                    'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
                    else => {
                        tok.i -= 1;
                        return Token.init(Token.Id.Identifier, tok.str[start..tok.i]);
                    },
                },
                State.Integer => switch (c) {
                    '0'...'9' => {},
                    else => {
                        tok.i -= 1;
                        return Token.init(Token.Id.Integer, tok.str[start..tok.i]);
                    },
                },
            }
        }

        return switch (state) {
            State.Begin => Token.init(Token.Id.Eos, tok.str[start..tok.i]),
            State.Identifier => Token.init(Token.Id.Identifier, tok.str[start..tok.i]),
            State.Integer => Token.init(Token.Id.Integer, tok.str[start..tok.i]),
        };
    }
};

fn testTokenizer(str: []const u8, tokens: []const Token) void {
    var tok = Tokenizer.init(str);
    for (tokens) |t1| {
        const t2 = tok.next();
        debug.assert(t1.id == t2.id);
        debug.assert(mem.eql(u8, t1.str, t2.str));
    }

    debug.assert(tok.next().id == Token.Id.Eos);
}

test "Tokenizer" {
    testTokenizer("a", []Token{Token.init(Token.Id.Identifier, "a")});
    testTokenizer("aA", []Token{Token.init(Token.Id.Identifier, "aA")});
    testTokenizer("aA1", []Token{Token.init(Token.Id.Identifier, "aA1")});
    testTokenizer("1", []Token{Token.init(Token.Id.Integer, "1")});
    testTokenizer("01", []Token{Token.init(Token.Id.Integer, "01")});
    testTokenizer("987654321", []Token{Token.init(Token.Id.Integer, "987654321")});
    testTokenizer("[", []Token{Token.init(Token.Id.LBracket, "[")});
    testTokenizer("]", []Token{Token.init(Token.Id.RBracket, "]")});
    testTokenizer("*", []Token{Token.init(Token.Id.Star, "*")});
    testTokenizer("=", []Token{Token.init(Token.Id.Equal, "=")});
    testTokenizer(".", []Token{Token.init(Token.Id.Dot, ".")});
    testTokenizer(",", []Token{Token.init(Token.Id.Invalid, ",")});
    testTokenizer("a[1]=.", []Token{
        Token.init(Token.Id.Identifier, "a"),
        Token.init(Token.Id.LBracket, "["),
        Token.init(Token.Id.Integer, "1"),
        Token.init(Token.Id.RBracket, "]"),
        Token.init(Token.Id.Equal, "="),
        Token.init(Token.Id.Dot, "."),
    });
}

pub const Node = union(enum) {
    Field: Field,
    Index: Index,
    Value: Value,

    pub const Kind = @TagType(@This());

    pub const Field = struct {
        dot: Token,
        ident: Token,
    };

    pub const Index = struct {
        lbracket: Token,
        int: Token,
        rbracket: Token,
    };

    pub const Value = struct {
        equal: Token,
        value: Token,
    };

    pub fn first(node: Node) Token {
        return switch (node) {
            Node.Kind.Field => |field| field.dot,
            Node.Kind.Index => |index| index.lbracket,
            Node.Kind.Value => |value| value.equal,
        };
    }

    pub fn last(node: Node) Token {
        return switch (node) {
            Node.Kind.Field => |field| field.ident,
            Node.Kind.Index => |index| index.rbracket,
            Node.Kind.Value => |value| value.value,
        };
    }
};

pub const Parser = struct {
    pub const Error = struct {
        expected: []const Token.Id,
        found: Token,
    };

    pub const Result = union(enum) {
        Ok: Node,
        Error: Error,

        pub fn ok(res: Node) Result {
            return Result{ .Ok = res };
        }

        pub fn err(found: Token, expected: []const Token.Id) Result {
            return Result{
                .Error = Error{
                    .expected = expected,
                    .found = found,
                },
            };
        }
    };

    const State = union(enum) {
        Suffix,
        Field: Token,
        Index: Token,
        IndexEnd: [2]Token,
        Done,
    };

    tok: Tokenizer,
    state: State,

    pub fn init(tok: Tokenizer) Parser {
        return Parser{
            .tok = tok,
            .state = State.Suffix,
        };
    }

    pub fn next(par: *Parser) Result {
        var token = Token.init(Token.Id.Invalid, par.tok.rest());
        while (true) {
            token = par.tok.next();
            switch (par.state) {
                State.Suffix => switch (token.id) {
                    Token.Id.Dot => par.state = State{ .Field = token },
                    Token.Id.LBracket => par.state = State{ .Index = token },
                    Token.Id.Equal => {
                        par.state = State.Done;
                        return Result.ok(Node{
                            .Value = Node.Value{
                                .equal = token,
                                .value = Token.init(Token.Id.Identifier, par.tok.rest()),
                            },
                        });
                    },
                    else => break,
                },
                State.Field => |dot| switch (token.id) {
                    Token.Id.Identifier => {
                        par.state = State.Suffix;
                        return Result.ok(Node{
                            .Field = Node.Field{
                                .dot = dot,
                                .ident = token,
                            },
                        });
                    },
                    else => break,
                },
                State.Index => |lbracket| switch (token.id) {
                    Token.Id.Integer => par.state = State{ .IndexEnd = []Token{ lbracket, token } },
                    else => break,
                },
                State.IndexEnd => |tokens| switch (token.id) {
                    Token.Id.RBracket => {
                        par.state = State.Suffix;
                        return Result.ok(Node{
                            .Index = Node.Index{
                                .lbracket = tokens[0],
                                .int = tokens[1],
                                .rbracket = token,
                            },
                        });
                    },
                    else => break,
                },
                State.Done => break,
            }
        }

        return switch (par.state) {
            State.Suffix => Result.err(token, []Token.Id{
                Token.Id.Dot,
                Token.Id.LBracket,
                Token.Id.Equal,
            }),
            State.Field => Result.err(token, []Token.Id{Token.Id.Identifier}),
            State.Index => Result.err(token, []Token.Id{Token.Id.Integer}),
            State.IndexEnd => Result.err(token, []Token.Id{Token.Id.RBracket}),
            State.Done => Result.err(token, []Token.Id{}),
        };
    }
};

fn testParser(str: []const u8, nodes: []const Node) void {
    var parser = Parser.init(Tokenizer.init(str));
    for (nodes) |n1| {
        const n2 = parser.next().Ok;
        switch (n1) {
            Node.Kind.Field => |f1| {
                const f2 = n2.Field;
                debug.assert(f1.ident.id == f2.ident.id);
                debug.assert(mem.eql(u8, f1.ident.str, f2.ident.str));
            },
            Node.Kind.Index => |in1| {
                const in2 = n2.Index;
                debug.assert(in1.lbracket.id == in2.lbracket.id);
                debug.assert(mem.eql(u8, in1.lbracket.str, in2.lbracket.str));
                debug.assert(in1.int.id == in2.int.id);
                debug.assert(mem.eql(u8, in1.int.str, in2.int.str));
                debug.assert(in1.rbracket.id == in2.rbracket.id);
                debug.assert(mem.eql(u8, in1.rbracket.str, in2.rbracket.str));
            },
            Node.Kind.Value => |v1| {
                const v2 = n2.Value;
                debug.assert(v1.equal.id == v2.equal.id);
                debug.assert(mem.eql(u8, v1.equal.str, v2.equal.str));
                debug.assert(v1.value.id == v2.value.id);
                debug.assert(mem.eql(u8, v1.value.str, v2.value.str));
            },
        }
    }

    debug.assert(parser.state == Parser.State.Done);
}

test "Parser" {
    testParser("=1", []Node{Node{
        .Value = Node.Value{
            .equal = Token.init(Token.Id.Equal, "="),
            .value = Token.init(Token.Id.Identifier, "1"),
        },
    }});
    testParser(".a=1", []Node{
        Node{
            .Field = Node.Field{
                .dot = Token.init(Token.Id.Dot, "."),
                .ident = Token.init(Token.Id.Identifier, "a"),
            },
        },
        Node{
            .Value = Node.Value{
                .equal = Token.init(Token.Id.Equal, "="),
                .value = Token.init(Token.Id.Identifier, "1"),
            },
        },
    });
    testParser(".a.b=1", []Node{
        Node{
            .Field = Node.Field{
                .dot = Token.init(Token.Id.Dot, ""),
                .ident = Token.init(Token.Id.Identifier, "a"),
            },
        },
        Node{
            .Field = Node.Field{
                .dot = Token.init(Token.Id.Dot, "."),
                .ident = Token.init(Token.Id.Identifier, "b"),
            },
        },
        Node{
            .Value = Node.Value{
                .equal = Token.init(Token.Id.Equal, "="),
                .value = Token.init(Token.Id.Identifier, "1"),
            },
        },
    });
    testParser(".a[1]=1", []Node{
        Node{
            .Field = Node.Field{
                .dot = Token.init(Token.Id.Dot, ""),
                .ident = Token.init(Token.Id.Identifier, "a"),
            },
        },
        Node{
            .Index = Node.Index{
                .lbracket = Token.init(Token.Id.LBracket, "["),
                .int = Token.init(Token.Id.Integer, "1"),
                .rbracket = Token.init(Token.Id.RBracket, "]"),
            },
        },
        Node{
            .Value = Node.Value{
                .equal = Token.init(Token.Id.Equal, "="),
                .value = Token.init(Token.Id.Identifier, "1"),
            },
        },
    });
}

pub const Pattern = union(enum) {
    Field: Field,
    FieldAny: FieldAny,
    Index: Index,
    IndexAny: IndexAny,

    pub const Kind = @TagType(@This());

    pub const Field = struct {
        dot: Token,
        ident: Token,
    };

    pub const FieldAny = struct {
        dot: Token,
        star: Token,
    };

    pub const Index = struct {
        lbracket: Token,
        int: Token,
        rbracket: Token,
    };

    pub const IndexAny = struct {
        lbracket: Token,
        star: Token,
        rbracket: Token,
    };

    pub fn first(pat: Pattern) Token {
        return switch (Pattern) {
            Pattern.Kind.Field => |field| field.dot,
            Pattern.Kind.FieldAny => |field| field.dot,
            Pattern.Kind.Index => |index| index.lbracket,
            Pattern.Kind.IndexAny => |index| index.lbracket,
        };
    }

    pub fn last(pat: Pattern) Token {
        return switch (Pattern) {
            Pattern.Kind.Field => |field| field.ident,
            Pattern.Kind.FieldAny => |field| field.star,
            Pattern.Kind.Index => |index| index.rbracket,
            Pattern.Kind.IndexAny => |index| index.rbracket,
        };
    }

    pub fn match(pat: Pattern, node: Node) bool {
        return switch (pat) {
            Kind.Field => |f1| switch (node) {
                Node.Kind.Field => |f2| mem.eql(u8, f1.ident.str, f2.ident.str),
                else => false,
            },
            Kind.FieldAny => node == Node.Kind.Field,
            Kind.Index => |in1| switch (node) {
                Node.Kind.Index => |in2| mem.eql(u8, in1.int.str, in2.int.str),
                else => false,
            },
            Kind.IndexAny => node == Node.Kind.Index,
        };
    }
};

pub const PatternParser = struct {
    pub const Error = struct {
        expected: []const Token.Id,
        found: Token,
    };

    pub const Result = union(enum) {
        Ok: Pattern,
        Error: Error,

        pub fn ok(res: Pattern) Result {
            return Result{ .Ok = res };
        }

        pub fn err(found: Token, expected: []const Token.Id) Result {
            return Result{
                .Error = Error{
                    .expected = expected,
                    .found = found,
                },
            };
        }
    };

    const State = union(enum) {
        Suffix,
        Field: Token,
        Index: Token,
        IndexEnd: [2]Token,
        IndexAnyEnd: [2]Token,
        Done,
    };

    tok: Tokenizer,
    state: State,

    pub fn init(tok: Tokenizer) PatternParser {
        return PatternParser{
            .tok = tok,
            .state = State.Suffix,
        };
    }

    pub fn next(par: *PatternParser) ?Result {
        var token = Token.init(Token.Id.Invalid, par.tok.rest());
        while (true) {
            token = par.tok.next();
            switch (par.state) {
                State.Suffix => switch (token.id) {
                    Token.Id.Dot => par.state = State{ .Field = token },
                    Token.Id.LBracket => par.state = State{ .Index = token },
                    Token.Id.Eos => {
                        par.state = State.Done;
                        return null;
                    },
                    else => break,
                },
                State.Field => |dot| switch (token.id) {
                    Token.Id.Identifier => {
                        par.state = State.Suffix;
                        return Result.ok(Pattern{
                            .Field = Pattern.Field{
                                .dot = dot,
                                .ident = token,
                            },
                        });
                    },
                    Token.Id.Star => {
                        par.state = State.Suffix;
                        return Result.ok(Pattern{
                            .FieldAny = Pattern.FieldAny{
                                .dot = dot,
                                .star = token,
                            },
                        });
                    },
                    else => break,
                },
                State.Index => |lbracket| switch (token.id) {
                    Token.Id.Integer => par.state = State{ .IndexEnd = []Token{ lbracket, token } },
                    Token.Id.Star => par.state = State{ .IndexAnyEnd = []Token{ lbracket, token } },
                    else => break,
                },
                State.IndexEnd => |tokens| switch (token.id) {
                    Token.Id.RBracket => {
                        par.state = State.Suffix;
                        return Result.ok(Pattern{
                            .Index = Pattern.Index{
                                .lbracket = tokens[0],
                                .int = tokens[1],
                                .rbracket = token,
                            },
                        });
                    },
                    else => break,
                },
                State.IndexAnyEnd => |tokens| switch (token.id) {
                    Token.Id.RBracket => {
                        par.state = State.Suffix;
                        return Result.ok(Pattern{
                            .IndexAny = Pattern.IndexAny{
                                .lbracket = tokens[0],
                                .star = tokens[1],
                                .rbracket = token,
                            },
                        });
                    },
                    else => break,
                },
                State.Done => break,
            }
        }

        return switch (par.state) {
            State.Suffix => Result.err(token, []Token.Id{
                Token.Id.Dot,
                Token.Id.LBracket,
                Token.Id.Equal,
            }),
            State.Field => Result.err(token, []Token.Id{
                Token.Id.Identifier,
                Token.Id.Star,
            }),
            State.Index => Result.err(token, []Token.Id{
                Token.Id.Integer,
                Token.Id.Star,
            }),
            State.IndexEnd => Result.err(token, []Token.Id{Token.Id.RBracket}),
            State.IndexAnyEnd => Result.err(token, []Token.Id{Token.Id.RBracket}),
            State.Done => Result.err(token, []Token.Id{}),
        };
    }
};

fn testPatternParser(str: []const u8, patterns: []const Pattern) void {
    var parser = PatternParser.init(Tokenizer.init(str));
    for (patterns) |p1| {
        const pat = parser.next().?;
        const p2 = pat.Ok;
        switch (p1) {
            Pattern.Kind.Field => |f1| {
                const f2 = p2.Field;
                debug.assert(f1.ident.id == f2.ident.id);
                debug.assert(mem.eql(u8, f1.ident.str, f2.ident.str));
            },
            Pattern.Kind.FieldAny => |f1| {
                const f2 = p2.FieldAny;
                debug.assert(f1.star.id == f2.star.id);
                debug.assert(mem.eql(u8, f1.star.str, f2.star.str));
            },
            Pattern.Kind.Index => |in1| {
                const in2 = p2.Index;
                debug.assert(in1.lbracket.id == in2.lbracket.id);
                debug.assert(mem.eql(u8, in1.lbracket.str, in2.lbracket.str));
                debug.assert(in1.int.id == in2.int.id);
                debug.assert(mem.eql(u8, in1.int.str, in2.int.str));
                debug.assert(in1.rbracket.id == in2.rbracket.id);
                debug.assert(mem.eql(u8, in1.rbracket.str, in2.rbracket.str));
            },
            Pattern.Kind.IndexAny => |in1| {
                const in2 = p2.IndexAny;
                debug.assert(in1.lbracket.id == in2.lbracket.id);
                debug.assert(mem.eql(u8, in1.lbracket.str, in2.lbracket.str));
                debug.assert(in1.star.id == in2.star.id);
                debug.assert(mem.eql(u8, in1.star.str, in2.star.str));
                debug.assert(in1.rbracket.id == in2.rbracket.id);
                debug.assert(mem.eql(u8, in1.rbracket.str, in2.rbracket.str));
            },
        }
    }

    _ = parser.next();
    debug.assert(parser.state == PatternParser.State.Done);
}

test "PatternParser" {
    testPatternParser(".a", []Pattern{Pattern{
        .Field = Pattern.Field{
            .dot = Token.init(Token.Id.Dot, ""),
            .ident = Token.init(Token.Id.Identifier, "a"),
        },
    }});
    testPatternParser(".a.b", []Pattern{
        Pattern{
            .Field = Pattern.Field{
                .dot = Token.init(Token.Id.Dot, "."),
                .ident = Token.init(Token.Id.Identifier, "a"),
            },
        },
        Pattern{
            .Field = Pattern.Field{
                .dot = Token.init(Token.Id.Dot, "."),
                .ident = Token.init(Token.Id.Identifier, "b"),
            },
        },
    });
    testPatternParser(".a[1]", []Pattern{
        Pattern{
            .Field = Pattern.Field{
                .dot = Token.init(Token.Id.Dot, "."),
                .ident = Token.init(Token.Id.Identifier, "a"),
            },
        },
        Pattern{
            .Index = Pattern.Index{
                .lbracket = Token.init(Token.Id.LBracket, "["),
                .int = Token.init(Token.Id.Integer, "1"),
                .rbracket = Token.init(Token.Id.RBracket, "]"),
            },
        },
    });
    testPatternParser(".*", []Pattern{Pattern{
        .FieldAny = Pattern.FieldAny{
            .dot = Token.init(Token.Id.Dot, "."),
            .star = Token.init(Token.Id.Star, "*"),
        },
    }});
    testPatternParser(".a.*", []Pattern{
        Pattern{
            .Field = Pattern.Field{
                .dot = Token.init(Token.Id.Dot, "."),
                .ident = Token.init(Token.Id.Identifier, "a"),
            },
        },
        Pattern{
            .FieldAny = Pattern.FieldAny{
                .dot = Token.init(Token.Id.Dot, "."),
                .star = Token.init(Token.Id.Star, "*"),
            },
        },
    });
    testPatternParser(".a[*]", []Pattern{
        Pattern{
            .Field = Pattern.Field{
                .dot = Token.init(Token.Id.Dot, "."),
                .ident = Token.init(Token.Id.Identifier, "a"),
            },
        },
        Pattern{
            .IndexAny = Pattern.IndexAny{
                .lbracket = Token.init(Token.Id.LBracket, "["),
                .star = Token.init(Token.Id.Star, "*"),
                .rbracket = Token.init(Token.Id.RBracket, "]"),
            },
        },
    });
}

pub fn Matcher(comptime pattern_strings: []const []const u8) type {
    var max_nodes = 0;
    var max_anys = 0;
    const patterns = comptime blk: {
        var res: []const []const Pattern = [][]const Pattern{};
        for (pattern_strings) |str| {
            var anys = 0;
            var pattern: []const Pattern = []Pattern{};
            var parser = PatternParser.init(Tokenizer.init(str));
            while (parser.next()) |r| switch (r) {
                PatternParser.Result.Ok => |pat| {
                    switch (pat) {
                        Pattern.Kind.FieldAny, Pattern.Kind.IndexAny => anys += 1,
                        else => {},
                    }

                    pattern = pattern ++ []Pattern{pat};
                },
                PatternParser.Result.Error => |err| {
                    @compileError("Expected ??? found " ++ err.found.str);
                },
            };

            if (max_anys < anys)
                max_anys = anys;
            if (max_nodes < pattern.len)
                max_nodes = pattern.len;
            res = res ++ [][]const Pattern{pattern};
        }

        break :blk res;
    };

    return struct {
        pub const Result = struct {
            anys: [max_anys]Token,
            value: Token,
            case: usize,
        };

        const no_match = Result{
            .anys = undefined,
            .value = undefined,
            .case = patterns.len,
        };

        pub fn match(str: []const u8) !Result {
            var parser = Parser.init(Tokenizer.init(str));
            var nodes_array: [max_nodes + 1]Node = undefined;
            var nodes = blk: {
                var size: usize = 0;
                for (nodes_array) |*node| {
                    switch (parser.next()) {
                        Parser.Result.Ok => |n| {
                            node.* = n;
                            size += 1;
                            if (n == Node.Kind.Value)
                                break;
                        },
                        Parser.Result.Error => return error.SyntaxError,
                    }
                }

                if (parser.state != Parser.State.Done)
                    return no_match;

                break :blk nodes_array[0..size];
            };

            // TODO: Can we generate a state machine instead of this?
            next: for (patterns) |pattern, i| {
                var curr_any: usize = 0;
                var anys: [max_anys]Token = undefined;
                if (nodes.len - 1 != pattern.len)
                    continue :next;

                for (pattern) |pat, j| {
                    const node = nodes[j];
                    if (!pat.match(node))
                        continue :next;

                    switch (pat) {
                        Pattern.Kind.IndexAny => {
                            anys[curr_any] = node.Index.int;
                            curr_any += 1;
                        },
                        Pattern.Kind.FieldAny => {
                            anys[curr_any] = node.Field.ident;
                            curr_any += 1;
                        },
                        else => {},
                    }
                }

                const value = nodes[nodes.len - 1];
                debug.assert(value == Node.Kind.Value);

                return Result{
                    .anys = anys,
                    .value = value.Value.value,
                    .case = i,
                };
            }

            return no_match;
        }

        pub fn case(comptime str: []const u8) comptime_int {
            for (pattern_strings) |pat, i| {
                if (mem.eql(u8, pat, str))
                    return i;
            }

            @compileError("Unknown case \"" ++ str ++ "\"");
        }
    };
}

test "Matcher" {
    const m = Matcher([][]const u8{
        "",
        ".a",
        ".a.*",
        ".a.*.*",
        ".a.*[*].*[*]",
        ".a[*]",
        ".a[*][*]",
    });

    const Test = struct {
        str: []const u8,
        case: usize,
        value: []const u8,
        anys: []const []const u8,
    };

    for ([]Test{
        Test{
            .str = "=1",
            .case = m.case(""),
            .value = "1",
            .anys = [][]const u8{},
        },
        Test{
            .str = ".a=1",
            .case = m.case(".a"),
            .value = "1",
            .anys = [][]const u8{},
        },
        Test{
            .str = ".a.b=2",
            .case = m.case(".a.*"),
            .value = "2",
            .anys = [][]const u8{"b"},
        },
        Test{
            .str = ".a.b.c=3",
            .case = m.case(".a.*.*"),
            .value = "3",
            .anys = [][]const u8{ "b", "c" },
        },
        Test{
            .str = ".a[1]=4",
            .case = m.case(".a[*]"),
            .value = "4",
            .anys = [][]const u8{"1"},
        },
        Test{
            .str = ".a[1][2]=5",
            .case = m.case(".a[*][*]"),
            .value = "5",
            .anys = [][]const u8{ "1", "2" },
        },
        Test{
            .str = ".a.b[1].c[2]=6",
            .case = m.case(".a.*[*].*[*]"),
            .value = "6",
            .anys = [][]const u8{ "b", "1", "c", "2" },
        },
    }) |t| {
        const match = try m.match(t.str);
        debug.assert(match.case == t.case);
        debug.assert(mem.eql(u8, match.value.str, t.value));
        for (t.anys) |a, i|
            debug.assert(mem.eql(u8, match.anys[i].str, a));
    }
}

/// Line <- Suffix* '=' .*
///
/// Suffix
///    <- '.' IDENTIFIER
///     / '[' INTEGER ']'
///
/// INTEGER <- [0-9]+
/// IDENTIFIER <- [a-zA-Z][A-Za-z0-9_]*
///
pub const StrParser = struct {
    str: []const u8,

    pub fn init(str: []const u8) StrParser {
        return StrParser{ .str = str };
    }

    pub fn peek(parser: *@This()) !u8 {
        if (parser.str.len == 0)
            return error.EndOfString;

        return parser.str[0];
    }

    pub fn eat(parser: *@This()) !u8 {
        const c = try parser.peek();
        parser.str = parser.str[1..];
        return c;
    }

    pub fn eatChar(parser: *@This(), c: u8) !void {
        const reset = parser.*;
        errdefer parser.* = reset;

        if (c != try parser.eat())
            return error.InvalidCharacter;
    }

    pub fn eatStr(parser: *@This(), str: []const u8) !void {
        if (parser.str.len < str.len)
            return error.EndOfString;
        if (!mem.startsWith(u8, parser.str, str))
            return error.InvalidCharacter;

        parser.str = parser.str[str.len..];
    }

    pub fn eatUnsigned(parser: *@This(), comptime Int: type, base: u8) !Int {
        const reset = parser.*;
        errdefer parser.* = reset;

        var res: Int = try math.cast(Int, try charToDigit(try parser.eat(), base));
        while (true) {
            const c = parser.peek() catch return res;
            const digit = charToDigit(c, base) catch return res;
            _ = parser.eat() catch unreachable;

            res = try math.mul(Int, res, try math.cast(Int, base));
            res = try math.add(Int, res, try math.cast(Int, digit));
        }
    }

    pub fn eatUnsignedMax(parser: *@This(), comptime Int: type, base: u8, max: var) !Int {
        const reset = parser.*;
        errdefer parser.* = reset;

        const res = try parser.eatUnsigned(Int, base);
        if (max <= res)
            return error.Overflow;

        return res;
    }

    pub fn eatUntil(parser: *@This(), c: u8) ![]const u8 {
        const reset = parser.*;
        errdefer parser.* = reset;

        var len: usize = 0;
        while (c != try parser.eat()) : (len += 1) {}

        return reset.str[0..len];
    }

    pub fn eatField(parser: *@This(), field: []const u8) !void {
        const reset = parser.*;
        errdefer parser.* = reset;
        try parser.eatChar('.');
        const f = try parser.eatAnyField();
        if (!mem.eql(u8, f, field))
            return error.InvalidField;
    }

    pub fn eatAnyField(parser: *@This()) ![]const u8 {
        for (parser.str) |c, i| {
            switch (c) {
                'a'...'z', 'A'...'Z', '0'...'9', '_' => {},
                else => {
                    defer parser.str = parser.str[i..];
                    return parser.str[0..i];
                },
            }
        }

        return error.EndOfString;
    }

    pub fn eatIndex(parser: *@This()) !usize {
        const reset = parser.*;
        errdefer parser.* = reset;

        _ = try parser.eatChar('[');
        const res = try parser.eatUnsigned(usize, 10);
        _ = try parser.eatChar(']');

        return res;
    }

    pub fn eatIndexMax(parser: *@This(), max: var) !usize {
        const reset = parser.*;
        errdefer parser.* = reset;

        const res = try parser.eatIndex();
        if (max <= res)
            return error.Overflow;

        return res;
    }

    pub fn eatValue(parser: *@This()) ![]const u8 {
        const reset = parser.*;
        errdefer parser.* = reset;
        try parser.eatChar('=');

        const res = parser.str;
        parser.str = res[res.len..];
        return res;
    }

    pub fn eatUnsignedValue(parser: *@This(), comptime Int: type, base: u8) !Int {
        const reset = parser.*;
        errdefer parser.* = reset;

        try parser.eatChar('=');
        const res = try parser.eatUnsigned(Int, base);

        if (parser.str.len != 0)
            return error.InvalidCharacter;

        return res;
    }

    pub fn eatUnsignedValueMax(parser: *@This(), comptime Int: type, base: u8, max: var) !Int {
        const reset = parser.*;
        errdefer parser.* = reset;

        const res = parser.eatUnsignedValue(Int, base);
        if (max <= res)
            return error.Overflow;

        return res;
    }

    pub fn eatEnumValue(parser: *@This(), comptime Enum: type) !Enum {
        const reset = parser.*;
        errdefer parser.* = reset;

        const str = try parser.eatValue();
        const res = std.meta.stringToEnum(Enum, str) orelse return error.InvalidValue;
        return res;
    }

    pub fn eatBoolValue(parser: *@This()) !bool {
        const Bool = enum {
            @"true",
            @"false",
        };
        const res = try parser.eatEnumValue(Bool);
        return res == Bool.@"true";
    }

    fn charToDigit(c: u8, base: u8) !u8 {
        const value = switch (c) {
            '0'...'9' => c - '0',
            'A'...'Z' => c - 'A' + 10,
            'a'...'z' => c - 'a' + 10,
            else => return error.InvalidCharacter,
        };

        if (value >= base)
            return error.InvalidCharacter;

        return value;
    }
};

test "Matcher.benchmark" {
    try bench.benchmark(struct {
        const args = [][]const u8{
            ".foo=0",
            ".foo.bar=0",
            ".foo.bar.baz=0",
            ".foo[0].bar[0].baz[0]=0",
            ".baz=0",
            ".baz.bar=0",
            ".baz.bar.foo=0",
            ".baz[0].bar[0].foo[0]=0",
            ".foo=9223372036854775807",
            ".foo.bar=9223372036854775807",
            ".foo.bar.baz=9223372036854775807",
            ".foo[9223372036854775807].bar[9223372036854775807].baz[9223372036854775807]=9223372036854775807",
            ".baz=9223372036854775807",
            ".baz.bar=9223372036854775807",
            ".baz.bar.foo=9223372036854775807",
            ".baz[9223372036854775807].bar[9223372036854775807].foo[9223372036854775807]=9223372036854775807",
        };

        const iterations = 100000;

        fn matcherSwitch(str: []const u8) !u128 {
            const m = Matcher([][]const u8{
                ".foo",
                ".foo.bar",
                ".foo.bar.baz",
                ".foo[*].bar[*].baz[*]",
                ".baz",
                ".baz.bar",
                ".baz.bar.foo",
                ".baz[*].bar[*].foo[*]",
            });

            const match = try m.match(str);
            switch (match.case) {
                m.case(".foo") => return u128(try fmt.parseUnsigned(u64, match.value.str, 10)),
                m.case(".foo.bar") => return u128(try fmt.parseUnsigned(u64, match.value.str, 10)),
                m.case(".foo.bar.baz") => return u128(try fmt.parseUnsigned(u64, match.value.str, 10)),
                m.case(".foo[*].bar[*].baz[*]") => {
                    const a = try fmt.parseUnsigned(u64, match.anys[0].str, 10);
                    const b = try fmt.parseUnsigned(u64, match.anys[1].str, 10);
                    const c = try fmt.parseUnsigned(u64, match.anys[2].str, 10);
                    const d = try fmt.parseUnsigned(u64, match.value.str, 10);
                    return u128(a) + b + c + d;
                },
                m.case(".baz") => return u128(try fmt.parseUnsigned(u64, match.value.str, 10)),
                m.case(".baz.bar") => return u128(try fmt.parseUnsigned(u64, match.value.str, 10)),
                m.case(".baz.bar.foo") => return u128(try fmt.parseUnsigned(u64, match.value.str, 10)),
                m.case(".baz[*].bar[*].foo[*]") => {
                    const a = try fmt.parseUnsigned(u64, match.anys[0].str, 10);
                    const b = try fmt.parseUnsigned(u64, match.anys[1].str, 10);
                    const c = try fmt.parseUnsigned(u64, match.anys[2].str, 10);
                    const d = try fmt.parseUnsigned(u64, match.value.str, 10);
                    return u128(a) + b + c + d;
                },
                else => unreachable,
            }
        }

        fn sscanSwitch(str: []const u8) !u128 {
            const Val = struct {
                a: u64,
            };
            const Val2 = struct {
                a: u64,
                b: u64,
                c: u64,
                d: u64,
            };

            if (sscan(str, ".foo={}", Val)) |v| {
                return u128(v.a);
            } else |_| if (sscan(str, ".foo.bar={}", Val)) |v| {
                return u128(v.a);
            } else |_| if (sscan(str, ".foo.bar.baz={}", Val)) |v| {
                return u128(v.a);
            } else |_| if (sscan(str, ".foo[{}].bar[{}].baz[{}]={}", Val2)) |v| {
                return u128(v.a) + v.b + v.c + v.d;
            } else |_| if (sscan(str, ".baz={}", Val)) |v| {
                return u128(v.a);
            } else |_| if (sscan(str, ".baz.bar={}", Val)) |v| {
                return u128(v.a);
            } else |_| if (sscan(str, ".baz.bar.foo={}", Val)) |v| {
                return u128(v.a);
            } else |_| if (sscan(str, ".baz[{}].bar[{}].foo[{}]={}", Val2)) |v| {
                return u128(v.a) + v.b + v.c + v.d;
            } else |err| {
                return err;
            }
        }

        pub fn StrParserSwitch(str: []const u8) !u128 {
            var parser = StrParser.init(str);

            if (parser.eatStr(".foo=")) |_| {
                return u128(try parser.eatUnsigned(u64, 10));
            } else |_| if (parser.eatStr(".foo.bar=")) |_| {
                return u128(try parser.eatUnsigned(u64, 10));
            } else |_| if (parser.eatStr(".foo.bar.baz=")) |_| {
                return u128(try parser.eatUnsigned(u64, 10));
            } else |_| if (parser.eatStr(".foo")) |_| {
                const a = try parser.eatIndex();
                try parser.eatStr(".bar");
                const b = try parser.eatIndex();
                try parser.eatStr(".baz");
                const c = try parser.eatIndex();
                try parser.eatChar('=');
                const d = try parser.eatUnsigned(u64, 10);
                return u128(a) + b + c + d;
            } else |_| if (parser.eatStr(".baz=")) |_| {
                return u128(try parser.eatUnsigned(u64, 10));
            } else |_| if (parser.eatStr(".baz.bar=")) |_| {
                return u128(try parser.eatUnsigned(u64, 10));
            } else |_| if (parser.eatStr(".baz.bar.foo=")) |_| {
                return u128(try parser.eatUnsigned(u64, 10));
            } else |_| if (parser.eatStr(".baz")) |_| {
                const a = try parser.eatIndex();
                try parser.eatStr(".bar");
                const b = try parser.eatIndex();
                try parser.eatStr(".foo");
                const c = try parser.eatIndex();
                try parser.eatChar('=');
                const d = try parser.eatUnsigned(u64, 10);
                return u128(a) + b + c + d;
            } else |err| {
                return err;
            }
        }

        pub fn StrParserSimplerSwitch(str: []const u8) !u128 {
            var parser = StrParser.init(str);

            if (parser.eatField("foo")) |_| {
                if (parser.eatUnsignedValue(u64, 10)) |value| {
                    return u128(value);
                } else |_| if (parser.eatField("bar")) {
                    if (parser.eatUnsignedValue(u64, 10)) |value| {
                        return u128(value);
                    } else |_| if (parser.eatField("baz")) {
                        return u128(try parser.eatUnsignedValue(u64, 10));
                    } else |err| {
                        return err;
                    }
                } else |_| if (parser.eatIndex()) |a| {
                    try parser.eatField("bar");
                    const b = try parser.eatIndex();
                    try parser.eatField("baz");
                    const c = try parser.eatIndex();
                    const d = try parser.eatUnsignedValue(u64, 10);
                    return u128(a) + b + c + d;
                } else |err| {
                    return err;
                }
            } else |_| if (parser.eatField("baz")) |_| {
                if (parser.eatUnsignedValue(u64, 10)) |value| {
                    return u128(value);
                } else |_| if (parser.eatField("bar")) {
                    if (parser.eatUnsignedValue(u64, 10)) |value| {
                        return u128(value);
                    } else |_| if (parser.eatField("foo")) {
                        return u128(try parser.eatUnsignedValue(u64, 10));
                    } else |err| {
                        return err;
                    }
                } else |_| if (parser.eatIndex()) |a| {
                    try parser.eatField("bar");
                    const b = try parser.eatIndex();
                    try parser.eatField("foo");
                    const c = try parser.eatIndex();
                    const d = try parser.eatUnsignedValue(u64, 10);
                    return u128(a) + b + c + d;
                } else |err| {
                    return err;
                }
            } else |err| {
                return err;
            }
        }
    });
}
