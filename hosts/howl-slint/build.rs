use std::{collections::HashMap, path::PathBuf};

fn main() {
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap();
    assert!(
        os == "linux" || os == "android" || os == "ios",
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
    } else if os == "ios" {
        assert_eq!(
            std::env::var("TARGET").unwrap(),
            "aarch64-apple-ios",
            "iPhone ARM64 is the initial iOS build target"
        );
        let output = std::process::Command::new("xcrun")
            .args(["--sdk", "iphoneos", "--show-sdk-path"])
            .output()
            .expect("iOS builds require macOS and Xcode");
        assert!(output.status.success(), "iPhoneOS SDK lookup failed");
        let sdk = PathBuf::from(String::from_utf8(output.stdout).unwrap().trim());
        assert!(
            sdk.join("usr/include/string.h").is_file(),
            "iPhoneOS libc headers missing"
        );
        let mut cxx = sdk.join("usr/include/c++/v1");
        if !cxx.join("vector").is_file() {
            let output = std::process::Command::new("xcrun")
                .args(["--sdk", "iphoneos", "--find", "clang++"])
                .output()
                .expect("Xcode C++ compiler lookup failed");
            assert!(output.status.success(), "Xcode C++ compiler lookup failed");
            let clang = PathBuf::from(String::from_utf8(output.stdout).unwrap().trim());
            cxx = clang
                .parent()
                .unwrap()
                .parent()
                .unwrap()
                .join("include/c++/v1");
        }
        assert!(cxx.join("vector").is_file(), "Xcode libc++ headers missing");
        zig.args([
            "-Dtarget=aarch64-ios.16.6",
            "-Dbundled_text=true",
            "build-static",
            "--sysroot",
        ])
        .arg(&sdk)
        .env("SDKROOT", &sdk)
        .env("C_INCLUDE_PATH", sdk.join("usr/include"))
        .env(
            "CPLUS_INCLUDE_PATH",
            format!("{}:{}", sdk.join("usr/include").display(), cxx.display()),
        );
        println!("cargo:rerun-if-env-changed=SDKROOT");
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
    let mut adapter = cc::Build::new();
    adapter
        .file("native/remote.c")
        .file("native/cpu.c")
        .include(prefix.join("include"))
        .flag("-std=c11")
        .warnings_into_errors(true);
    if os == "ios" {
        adapter.object(prefix.join("lib/howl_sessions_native.o"));
    }
    adapter.compile("slint_terminal");
    println!(
        "cargo:rustc-link-search=native={}",
        prefix.join("lib").display()
    );
    if os == "ios" {
        cc::Build::new()
            .file("native/ios.m")
            .flag("-fobjc-arc")
            .warnings_into_errors(true)
            .compile("slint_ios");
        println!("cargo:rustc-link-lib=c++");
        for framework in ["Foundation", "UIKit", "CoreText", "CoreFoundation"] {
            println!("cargo:rustc-link-lib=framework={framework}");
        }
    } else {
        println!("cargo:rustc-link-lib=dylib=howl_sessions_native");
    }
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
        "native/ios.m",
        "native/build.zig",
        "native/build.zig.zon",
    ] {
        println!("cargo:rerun-if-changed={path}");
    }
    let libraries = HashMap::from([("lucide".into(), PathBuf::from(lucide_slint::lib()))]);
    let config = slint_build::CompilerConfiguration::new().with_library_paths(libraries);
    slint_build::compile_with_config("src/ui/app.slint", config).expect("Slint compilation failed");
}
