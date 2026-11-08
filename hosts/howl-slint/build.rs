use std::{collections::HashMap, path::PathBuf};

fn main() {
    if std::env::var_os("CARGO_FEATURE_TERMINAL_PROOF").is_some() {
        assert_eq!(
            std::env::var("CARGO_CFG_TARGET_OS").unwrap(),
            "linux",
            "local terminal proof is Linux-only"
        );
        assert_eq!(
            std::env::var("HOST").unwrap(),
            std::env::var("TARGET").unwrap(),
            "local terminal proof does not yet support cross-compilation"
        );
        let prefix = PathBuf::from(std::env::var_os("OUT_DIR").unwrap()).join("howl");
        let result = std::process::Command::new("zig")
            .current_dir("native")
            .args(["build", "-Doptimize=ReleaseSafe", "-j2", "--prefix"])
            .arg(&prefix)
            .status()
            .expect("run pinned Zig build");
        assert!(result.success(), "Howl native build failed");
        cc::Build::new()
            .file("native/terminal.c")
            .include(prefix.join("include"))
            .flag("-std=c11")
            .compile("slint_terminal_proof");
        println!(
            "cargo:rustc-link-search=native={}",
            prefix.join("lib").display()
        );
        println!("cargo:rustc-link-lib=static=howl_instance_native");
        println!("cargo:rustc-link-lib=static=howl_vt_native");
        for lib in ["freetype", "harfbuzz", "m", "pthread", "dl"] {
            println!("cargo:rustc-link-lib={lib}");
        }
        for path in [
            "native/terminal.c",
            "native/build.zig",
            "native/build.zig.zon",
        ] {
            println!("cargo:rerun-if-changed={path}");
        }
    }
    let libraries = HashMap::from([("lucide".into(), PathBuf::from(lucide_slint::lib()))]);
    let config = slint_build::CompilerConfiguration::new().with_library_paths(libraries);
    slint_build::compile_with_config("src/ui/app.slint", config).expect("Slint compilation failed");
}
