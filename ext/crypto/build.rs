//! Build script for lunet-crypto: locate a STATIC libsodium archive and
//! link it into the cdylib. Zero crate dependencies, so this drives
//! `pkg-config` (Unix) or probes the workspace vcpkg tree (Windows) by
//! hand.
//!
//! libsodium is linked STATICALLY. This script hard-fails the build when
//! no static archive is found; it never falls back to the shared library.
//!
//! Resolution order:
//!   1. `LUNET_CRYPTO_SODIUM_LIB_DIR` env var — directory containing
//!      `libsodium.a` (Unix) or `libsodium.lib` (Windows).
//!   2. Unix: `pkg-config --libs --static libsodium`, parsing its `-L`
//!      flags by hand, then verifying `libsodium.a` exists in one of the
//!      reported directories.
//!   3. Windows: `%VCPKG_ROOT%\installed\x64-windows\lib\libsodium.lib`,
//!      then `<workspace>/vcpkg/installed/x64-windows/lib/libsodium.lib`.

use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=LUNET_CRYPTO_SODIUM_LIB_DIR");
    println!("cargo:rerun-if-env-changed=VCPKG_ROOT");

    let dir = locate();
    let src = dir.join(archive_name());
    println!("cargo:rerun-if-changed={}", src.display());

    // `static=sodium` alone is NOT enough on Unix: when libsodium.a and
    // the shared library sit in the SAME -L directory (Homebrew, Debian),
    // the linker resolves -lsodium to the shared library. The robust
    // zero-dep answer: copy the archive into a private OUT_DIR directory
    // that contains NO shared library, and put only that directory on the
    // search path.
    let out_dir =
        PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR is always set for build scripts"));
    let staged = out_dir.join(archive_name());
    if let Err(e) = std::fs::remove_file(&staged) {
        if e.kind() != std::io::ErrorKind::NotFound {
            panic!(
                "lunet-crypto build.rs: failed to clear the previously staged {}: {e}",
                staged.display()
            );
        }
    }
    std::fs::copy(&src, &staged).unwrap_or_else(|e| {
        panic!(
            "lunet-crypto build.rs: failed to stage {} into {}: {e}",
            src.display(),
            staged.display()
        )
    });
    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static={}", link_name());
    if env::var("CARGO_CFG_WINDOWS").is_ok() {
        println!("cargo:rustc-link-lib=advapi32");
    } else {
        println!("cargo:rustc-link-lib=pthread");
    }
}

fn locate() -> PathBuf {
    let archive = archive_name();

    if let Ok(dir) = env::var("LUNET_CRYPTO_SODIUM_LIB_DIR") {
        let dir = PathBuf::from(dir);
        if dir.join(archive).is_file() {
            return dir;
        }
        fatal(&format!(
            "LUNET_CRYPTO_SODIUM_LIB_DIR points at {}, which does not contain \
             {archive}. Static linking is required; no shared-library fallback.",
            dir.display()
        ));
    }

    if env::var("CARGO_CFG_WINDOWS").is_ok() {
        locate_vcpkg(archive)
    } else {
        locate_pkg_config(archive)
    }
}

fn locate_pkg_config(archive: &str) -> PathBuf {
    let mut search_dirs: Vec<PathBuf> = Vec::new();

    if let Ok(output) = Command::new("pkg-config")
        .args(["--libs", "--static", "libsodium"])
        .output()
    {
        if output.status.success() {
            let text = String::from_utf8_lossy(&output.stdout);
            let mut tokens = text.split_whitespace();
            while let Some(tok) = tokens.next() {
                if tok == "-L" {
                    if let Some(dir) = tokens.next() {
                        search_dirs.push(PathBuf::from(dir));
                    }
                } else if let Some(dir) = tok.strip_prefix("-L") {
                    search_dirs.push(PathBuf::from(dir));
                }
            }
        }
    }

    if let Ok(output) = Command::new("pkg-config")
        .args(["--variable=libdir", "libsodium"])
        .output()
    {
        if output.status.success() {
            let dir = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !dir.is_empty() {
                search_dirs.push(PathBuf::from(dir));
            }
        }
    }

    for dir in &[
        "/usr/lib/x86_64-linux-gnu",
        "/usr/lib/aarch64-linux-gnu",
        "/usr/lib64",
        "/usr/lib",
        "/usr/local/lib",
    ] {
        search_dirs.push(PathBuf::from(dir));
    }

    for dir in &search_dirs {
        if dir.join(archive).is_file() {
            return dir.clone();
        }
    }
    fatal(&format!(
        "pkg-config found libsodium but no static archive {archive} in \
         any of: {search_dirs:?}. No shared-library fallback. Both \
         libsodium-dev and Homebrew libsodium ship the archive; or set \
         LUNET_CRYPTO_SODIUM_LIB_DIR."
    ));
}

fn locate_vcpkg(archive: &str) -> PathBuf {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(root) = env::var("VCPKG_ROOT") {
        candidates.push(
            PathBuf::from(root)
                .join("installed")
                .join("x64-windows")
                .join("lib"),
        );
    }
    if let Ok(manifest) = env::var("CARGO_MANIFEST_DIR") {
        candidates.push(
            PathBuf::from(manifest)
                .join("..")
                .join("..")
                .join("vcpkg")
                .join("installed")
                .join("x64-windows")
                .join("lib"),
        );
    }
    for dir in &candidates {
        if dir.join(archive).is_file() {
            return dir.clone();
        }
    }
    fatal(&format!(
        "no static libsodium.lib found. Probed: {candidates:?}. Run \
         `vcpkg install libsodium:x64-windows` or set \
         LUNET_CRYPTO_SODIUM_LIB_DIR."
    ));
}

fn archive_name() -> &'static str {
    if env::var("CARGO_CFG_WINDOWS").is_ok() {
        "libsodium.lib"
    } else {
        "libsodium.a"
    }
}

fn link_name() -> &'static str {
    if env::var("CARGO_CFG_WINDOWS").is_ok() {
        "libsodium"
    } else {
        "sodium"
    }
}

fn fatal(msg: &str) -> ! {
    panic!("lunet-crypto build.rs: {msg}");
}
