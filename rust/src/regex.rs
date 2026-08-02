//! A small backtracking regex engine.
//!
//! Omni specs match error messages with `/pattern/` expectations, so every
//! port needs a regex. Rust has no regex in its standard library, and omni
//! adds no third-party dependencies, so it carries this one.
//!
//! Supported: literals, `.`, `^`, `$`, `|`, groups `(...)`, classes
//! `[a-z0-9_]` and `[^...]`, quantifiers `* + ? {m} {m,} {m,n}` (greedy,
//! and lazy with a trailing `?`), and the escapes `\d \D \w \W \s \S \n
//! \r \t` plus any escaped punctuation.

#[derive(Clone, Debug)]
enum Node {
    Char(char),
    Any,
    Class(Vec<ClassItem>, bool),
    Start,
    End,
    Seq(Vec<Node>),
    Alt(Vec<Node>),
    Repeat(Box<Node>, usize, Option<usize>, bool),
}

#[derive(Clone, Debug)]
enum ClassItem {
    Char(char),
    Range(char, char),
    Digit(bool),
    Word(bool),
    Space(bool),
}

/// A compiled regular expression.
pub struct Regex {
    root: Node,
}

impl Regex {
    /// Compile a pattern.
    pub fn new(pattern: &str) -> Result<Regex, String> {
        let chars: Vec<char> = pattern.chars().collect();
        let mut pos = 0usize;
        let root = parsealt(&chars, &mut pos)?;

        if pos < chars.len() {
            return Err(format!("omni: bad regex at {}: {}", pos, pattern));
        }

        Ok(Regex { root })
    }

    /// Is the pattern found anywhere in the text?
    pub fn is_match(&self, text: &str) -> bool {
        let chars: Vec<char> = text.chars().collect();

        for start in 0..=chars.len() {
            if matchnode(&self.root, &chars, start, &|_end| true) {
                return true;
            }
        }

        false
    }
}

fn parsealt(chars: &[char], pos: &mut usize) -> Result<Node, String> {
    let mut branches = vec![parseseq(chars, pos)?];

    while *pos < chars.len() && chars[*pos] == '|' {
        *pos += 1;
        branches.push(parseseq(chars, pos)?);
    }

    if 1 == branches.len() {
        return Ok(branches.remove(0));
    }

    Ok(Node::Alt(branches))
}

fn parseseq(chars: &[char], pos: &mut usize) -> Result<Node, String> {
    let mut nodes = Vec::new();

    while *pos < chars.len() && chars[*pos] != '|' && chars[*pos] != ')' {
        let atom = parseatom(chars, pos)?;
        nodes.push(parserepeat(chars, pos, atom)?);
    }

    Ok(Node::Seq(nodes))
}

fn parserepeat(chars: &[char], pos: &mut usize, atom: Node) -> Result<Node, String> {
    if *pos >= chars.len() {
        return Ok(atom);
    }

    let (min, max) = match chars[*pos] {
        '*' => {
            *pos += 1;
            (0usize, None)
        }
        '+' => {
            *pos += 1;
            (1usize, None)
        }
        '?' => {
            *pos += 1;
            (0usize, Some(1usize))
        }
        '{' => {
            let start = *pos;
            match parsecount(chars, pos) {
                Some(bounds) => bounds,
                None => {
                    *pos = start;
                    return Ok(atom);
                }
            }
        }
        _ => return Ok(atom),
    };

    let mut greedy = true;
    if *pos < chars.len() && chars[*pos] == '?' {
        greedy = false;
        *pos += 1;
    }

    Ok(Node::Repeat(Box::new(atom), min, max, greedy))
}

fn parsecount(chars: &[char], pos: &mut usize) -> Option<(usize, Option<usize>)> {
    let mut scan = *pos + 1; // {
    let mut minstr = String::new();

    while scan < chars.len() && chars[scan].is_ascii_digit() {
        minstr.push(chars[scan]);
        scan += 1;
    }

    if minstr.is_empty() {
        return None;
    }

    let min: usize = minstr.parse().ok()?;

    if scan < chars.len() && chars[scan] == '}' {
        *pos = scan + 1;
        return Some((min, Some(min)));
    }

    if scan >= chars.len() || chars[scan] != ',' {
        return None;
    }
    scan += 1;

    let mut maxstr = String::new();
    while scan < chars.len() && chars[scan].is_ascii_digit() {
        maxstr.push(chars[scan]);
        scan += 1;
    }

    if scan >= chars.len() || chars[scan] != '}' {
        return None;
    }
    *pos = scan + 1;

    if maxstr.is_empty() {
        return Some((min, None));
    }

    Some((min, Some(maxstr.parse().ok()?)))
}

fn parseatom(chars: &[char], pos: &mut usize) -> Result<Node, String> {
    let char = chars[*pos];

    if char == '(' {
        *pos += 1;

        // Non-capturing group syntax is accepted and ignored.
        if *pos + 1 < chars.len() && chars[*pos] == '?' && chars[*pos + 1] == ':' {
            *pos += 2;
        }

        let inner = parsealt(chars, pos)?;

        if *pos >= chars.len() || chars[*pos] != ')' {
            return Err("omni: unbalanced regex group".to_string());
        }
        *pos += 1;

        return Ok(inner);
    }

    if char == '[' {
        return parseclass(chars, pos);
    }

    if char == '.' {
        *pos += 1;
        return Ok(Node::Any);
    }

    if char == '^' {
        *pos += 1;
        return Ok(Node::Start);
    }

    if char == '$' {
        *pos += 1;
        return Ok(Node::End);
    }

    if char == '\\' {
        *pos += 1;
        if *pos >= chars.len() {
            return Err("omni: trailing backslash in regex".to_string());
        }
        let escape = chars[*pos];
        *pos += 1;
        return Ok(escapenode(escape));
    }

    *pos += 1;
    Ok(Node::Char(char))
}

fn escapenode(escape: char) -> Node {
    match escape {
        'd' => Node::Class(vec![ClassItem::Digit(false)], false),
        'D' => Node::Class(vec![ClassItem::Digit(false)], true),
        'w' => Node::Class(vec![ClassItem::Word(false)], false),
        'W' => Node::Class(vec![ClassItem::Word(false)], true),
        's' => Node::Class(vec![ClassItem::Space(false)], false),
        'S' => Node::Class(vec![ClassItem::Space(false)], true),
        'n' => Node::Char('\n'),
        'r' => Node::Char('\r'),
        't' => Node::Char('\t'),
        other => Node::Char(other),
    }
}

fn parseclass(chars: &[char], pos: &mut usize) -> Result<Node, String> {
    *pos += 1; // [

    let mut negated = false;
    if *pos < chars.len() && chars[*pos] == '^' {
        negated = true;
        *pos += 1;
    }

    let mut items = Vec::new();
    let mut first = true;

    while *pos < chars.len() {
        let char = chars[*pos];

        if char == ']' && !first {
            *pos += 1;
            return Ok(Node::Class(items, negated));
        }
        first = false;

        if char == '\\' {
            *pos += 1;
            if *pos >= chars.len() {
                break;
            }
            let escape = chars[*pos];
            *pos += 1;
            items.push(match escape {
                'd' => ClassItem::Digit(false),
                'D' => ClassItem::Digit(true),
                'w' => ClassItem::Word(false),
                'W' => ClassItem::Word(true),
                's' => ClassItem::Space(false),
                'S' => ClassItem::Space(true),
                'n' => ClassItem::Char('\n'),
                'r' => ClassItem::Char('\r'),
                't' => ClassItem::Char('\t'),
                other => ClassItem::Char(other),
            });
            continue;
        }

        *pos += 1;

        if *pos + 1 < chars.len() && chars[*pos] == '-' && chars[*pos + 1] != ']' {
            let end = chars[*pos + 1];
            *pos += 2;
            items.push(ClassItem::Range(char, end));
            continue;
        }

        items.push(ClassItem::Char(char));
    }

    Err("omni: unterminated regex class".to_string())
}

fn isword(char: char) -> bool {
    char.is_alphanumeric() || char == '_'
}

fn classmatch(items: &[ClassItem], negated: bool, char: char) -> bool {
    let mut hit = false;

    for item in items {
        let ok = match item {
            ClassItem::Char(want) => char == *want,
            ClassItem::Range(from, to) => *from <= char && char <= *to,
            ClassItem::Digit(invert) => char.is_ascii_digit() != *invert,
            ClassItem::Word(invert) => isword(char) != *invert,
            ClassItem::Space(invert) => char.is_whitespace() != *invert,
        };
        if ok {
            hit = true;
            break;
        }
    }

    hit != negated
}

fn matchnode(node: &Node, text: &[char], pos: usize, cont: &dyn Fn(usize) -> bool) -> bool {
    match node {
        Node::Char(want) => pos < text.len() && text[pos] == *want && cont(pos + 1),
        Node::Any => pos < text.len() && cont(pos + 1),
        Node::Class(items, negated) => {
            pos < text.len() && classmatch(items, *negated, text[pos]) && cont(pos + 1)
        }
        Node::Start => 0 == pos && cont(pos),
        Node::End => text.len() == pos && cont(pos),
        Node::Seq(nodes) => matchseq(nodes, 0, text, pos, cont),
        Node::Alt(branches) => branches
            .iter()
            .any(|branch| matchnode(branch, text, pos, cont)),
        Node::Repeat(inner, min, max, greedy) => {
            matchrepeat(inner, *min, *max, *greedy, 0, text, pos, cont)
        }
    }
}

fn matchseq(
    nodes: &[Node],
    index: usize,
    text: &[char],
    pos: usize,
    cont: &dyn Fn(usize) -> bool,
) -> bool {
    if index >= nodes.len() {
        return cont(pos);
    }

    matchnode(&nodes[index], text, pos, &|next| {
        matchseq(nodes, index + 1, text, next, cont)
    })
}

#[allow(clippy::too_many_arguments)]
fn matchrepeat(
    inner: &Node,
    min: usize,
    max: Option<usize>,
    greedy: bool,
    count: usize,
    text: &[char],
    pos: usize,
    cont: &dyn Fn(usize) -> bool,
) -> bool {
    let canmore = max.map(|limit| count < limit).unwrap_or(true);

    let takemore = || {
        canmore
            && matchnode(inner, text, pos, &|next| {
                // A zero-width repeat would loop forever.
                next > pos && matchrepeat(inner, min, max, greedy, count + 1, text, next, cont)
            })
    };

    let stopnow = || count >= min && cont(pos);

    if greedy {
        takemore() || stopnow()
    } else {
        stopnow() || takemore()
    }
}
