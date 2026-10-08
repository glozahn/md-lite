//! Standalone HTML for export and printing.

use super::html::escape;
use super::parse::options;

pub fn body(source: &str) -> String {
    let parser = pulldown_cmark::Parser::new_ext(source, options());
    let mut out = String::new();
    pulldown_cmark::html::push_html(&mut out, parser);
    out
}

/// A complete page. `print` keeps it light and drops the page margins the printer adds.
pub fn page(source: &str, title: &str, language: &str, print: bool) -> String {
    let scheme = if print { "light" } else { "light dark" };
    let dark = if print { "" } else { DARK };
    format!(
        r#"<!doctype html>
<html lang="{language}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="generator" content="MD Lite">
<title>{title}</title>
<style>
:root {{ color-scheme: {scheme}; }}
{CSS}
{dark}
</style>
</head>
<body>
<article>
{body}
</article>
</body>
</html>
"#,
        title = escape(title),
        body = body(source),
    )
}

const CSS: &str = r#"body { margin: 0; font: 17px/1.65 "Adwaita Sans", Cantarell, "Segoe UI", system-ui, sans-serif; color: #1f2328; background: #fbfaf7; }
article { max-width: 780px; margin: 0 auto; padding: 40px 32px 80px; }
h1, h2 { border-bottom: 1px solid rgba(0,0,0,.1); padding-bottom: .3em; }
h1, h2, h3, h4 { line-height: 1.25; margin: 1.5em 0 .6em; }
a { color: #0a84ff; }
img { max-width: 100%; }
code, pre { font-family: "Adwaita Mono", "DejaVu Sans Mono", ui-monospace, Menlo, Consolas, monospace; font-size: .86em; }
:not(pre) > code { background: rgba(0,0,0,.055); border-radius: 5px; padding: .12em .36em; }
pre { background: rgba(0,0,0,.035); border: 1px solid rgba(0,0,0,.06); border-radius: 10px; padding: 14px 16px; overflow-x: auto; }
blockquote { margin: 0 0 1em; padding: .1em 1em; border-left: 3px solid rgba(0,0,0,.15); color: #5f6670; }
blockquote[class^="markdown-alert"] { color: inherit; border-radius: 6px; }
.markdown-alert-note { border-color: #0969da; background: rgba(9,105,218,.06); }
.markdown-alert-tip { border-color: #1a7f37; background: rgba(26,127,55,.06); }
.markdown-alert-important { border-color: #8250df; background: rgba(130,80,223,.06); }
.markdown-alert-warning { border-color: #9a6700; background: rgba(154,103,0,.06); }
.markdown-alert-caution { border-color: #cf222e; background: rgba(207,34,46,.06); }
table { border-collapse: collapse; width: 100%; }
th, td { border: 1px solid rgba(0,0,0,.12); padding: .45em .8em; }
th { background: rgba(0,0,0,.04); }
hr { border: 0; border-top: 1px solid rgba(0,0,0,.12); margin: 1.6em 0; }
@media print { body { background: #fff; } article { padding: 0; max-width: none; } pre { white-space: pre-wrap; } }"#;

const DARK: &str = r#"@media (prefers-color-scheme: dark) {
  body { color: #e6e8eb; background: #16181c; }
  h1, h2 { border-color: rgba(255,255,255,.12); }
  :not(pre) > code { background: rgba(255,255,255,.1); }
  pre { background: rgba(255,255,255,.05); border-color: rgba(255,255,255,.07); }
  th, td { border-color: rgba(255,255,255,.12); }
  blockquote { color: #a2a8b1; border-color: rgba(255,255,255,.2); }
}"#;
