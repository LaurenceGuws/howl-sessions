use std::{collections::HashMap, path::PathBuf};

fn main() {
    let libraries = HashMap::from([("lucide".into(), PathBuf::from(lucide_slint::lib()))]);
    let config = slint_build::CompilerConfiguration::new().with_library_paths(libraries);
    slint_build::compile_with_config("src/ui/app.slint", config).expect("Slint compilation failed");
}
