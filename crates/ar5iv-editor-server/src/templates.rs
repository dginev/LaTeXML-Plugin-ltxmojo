use askama::Template;

#[derive(Template)]
#[template(path = "editor.html")]
pub struct EditorTemplate;

#[derive(Template)]
#[template(path = "about.html")]
pub struct AboutTemplate;

#[derive(Template)]
#[template(path = "help.html")]
pub struct HelpTemplate;
