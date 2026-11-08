fn main() -> Result<(), Box<dyn std::error::Error>> {
    let rustc = std::env::var("RUSTC")?;
    let rustc_version = std::process::Command::new(&rustc)
        .arg("--version")
        .output()?
        .stdout;
    let rustc_version = String::from_utf8(rustc_version)?;
    let rustc_version = rustc_version
        .strip_prefix("rustc ")
        .expect("unexpected rustc --version output")
        .trim_end();

    println!("cargo:rustc-env=ZEMENT_RUSTC_VERSION={rustc_version}");
    println!("cargo:rerun-if-env-changed=RUSTC");

    Ok(())
}