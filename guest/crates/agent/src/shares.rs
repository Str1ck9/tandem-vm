//! The host's answer to SHARE_LIST: `{"kind":"webdav","port":47123,"shares":["Home","Projects"]}`.
//! Parsed by hand to keep the agent free of dependencies; the format is fixed by PROTOCOL.md.

#[derive(Debug, PartialEq)]
pub struct Shares {
    pub port: u16,
    pub names: Vec<String>,
    /// How the folders reach the guest: `webdav` (the default), `9p` or `virtiofs`.
    pub kind: String,
}

/// The value of a top-level string field that needs no unescaping (`"kind":"9p"`).
fn plain_string(json: &str, key: &str) -> Option<String> {
    let at = json.find(&format!("\"{key}\""))? + key.len() + 2;
    let rest = json[at..].trim_start().strip_prefix(':')?.trim_start().strip_prefix('"')?;
    Some(rest[..rest.find('"')?].to_string())
}

pub fn parse(json: &str) -> Option<Shares> {
    let port_at = json.find("\"port\"")? + 6;
    let digits: String = json[port_at..].chars().skip_while(|c| *c == ':' || c.is_whitespace()).take_while(|c| c.is_ascii_digit()).collect();
    let port = digits.parse().ok()?;
    let list_at = json.find("\"shares\"")?;
    let open = list_at + json[list_at..].find('[')?;
    let mut names = Vec::new();
    let mut chars = json[open + 1..].chars();
    loop {
        match chars.next()? {
            ']' => break,
            '"' => {
                let mut name = String::new();
                loop {
                    match chars.next()? {
                        '"' => break,
                        '\\' => match chars.next()? {
                            'u' => {
                                let hex: String = chars.by_ref().take(4).collect();
                                name.push(char::from_u32(u32::from_str_radix(&hex, 16).ok()?)?);
                            }
                            'n' => name.push('\n'),
                            't' => name.push('\t'),
                            other => name.push(other),
                        },
                        c => name.push(c),
                    }
                }
                names.push(name);
            }
            _ => {}
        }
    }
    Some(Shares { port, names, kind: plain_string(json, "kind").unwrap_or_else(|| "webdav".into()) })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_host_reply() {
        assert_eq!(parse(r#"{"port":47123,"shares":["Home","My \"Stuff\"","caf\u00e9"]}"#),
                   Some(Shares { port: 47123, names: vec!["Home".into(), "My \"Stuff\"".into(), "café".into()], kind: "webdav".into() }));
        assert_eq!(parse(r#"{"shares":[],"port":0}"#), Some(Shares { port: 0, names: vec![], kind: "webdav".into() }));
        assert_eq!(parse(r#"{"kind" : "9p","port":0,"shares":["A"]}"#), Some(Shares { port: 0, names: vec!["A".into()], kind: "9p".into() }));
        assert_eq!(parse(r#"{"port":1}"#), None);
        assert_eq!(parse(r#"{"port":99999,"shares":[]}"#), None);
        assert_eq!(parse(r#"{"port":5,"shares":["unterminated"#), None);
    }
}
