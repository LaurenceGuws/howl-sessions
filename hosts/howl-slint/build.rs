use std::{collections::HashMap, path::PathBuf};

fn main() {
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    assert!(
        os == "linux" || os == "android",
        "unsupported native host target"
    );
    let prefix = PathBuf::from(std::env::var_os("OUT_DIR").unwrap()).join("howl");
    let mut zig = std::process::Command::new("zig");
    zig.current_dir("native")
        .args(["build", "-Doptimize=ReleaseSafe", "-j2", "--prefix"])
        .arg(&prefix);
    if os == "android" {
        assert_eq!(
            std::env::var("TARGET").unwrap(),
            "aarch64-linux-android",
            "Android ARM64 is the qualified build target"
        );
        zig.args([
            "-Dtarget=aarch64-linux-android.28",
            "-Dbundled_text=true",
            "--libc",
        ])
        .arg(
            std::env::var_os("HOWL_ANDROID_LIBC")
                .expect("HOWL_ANDROID_LIBC must name an NDK libc description"),
        );
        println!("cargo:rerun-if-env-changed=HOWL_ANDROID_LIBC");
    } else {
        assert_eq!(
            std::env::var("HOST").unwrap(),
            std::env::var("TARGET").unwrap(),
            "desktop cross-compilation not configured"
        );
    }
    assert!(
        zig.status().expect("run pinned Zig build").success(),
        "Howl native build failed"
    );
    cc::Build::new()
        .file("native/remote.c")
        .file("native/cpu.c")
        .include(prefix.join("include"))
        .flag("-std=c11")
        .warnings_into_errors(true)
        .compile("slint_terminal");
    println!(
        "cargo:rustc-link-search=native={}",
        prefix.join("lib").display()
    );
    println!("cargo:rustc-link-lib=dylib=howl_sessions_native");
    if os == "linux" {
        println!(
            "cargo:rustc-link-arg=-Wl,-rpath,{}",
            prefix.join("lib").display()
        );
    }
    for path in [
        "native/remote.c",
        "native/remote.h",
        "native/cpu.c",
        "native/cpu.h",
        "native/build.zig",
        "native/build.zig.zon",
    ] {
        println!("cargo:rerun-if-changed={path}");
    }
    let libraries = HashMap::from([("lucide".into(), PathBuf::from(lucide_slint::lib()))]);
    let config = slint_build::CompilerConfiguration::new().with_library_paths(libraries);
    slint_build::compile_with_config("src/ui/app.slint", config).expect("Slint compilation failed");
}
