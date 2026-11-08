#[cfg(feature = "intl")]
extern crate icu_capi;

#[cfg(feature = "temporal")]
extern crate temporal_capi;

#[unsafe(no_mangle)]
pub extern "C" fn zement_rustc_version() -> *const core::ffi::c_char {
    const VERSION: &str = concat!(env!("ZEMENT_RUSTC_VERSION"), "\0");
    VERSION.as_ptr() as *const core::ffi::c_char
}
