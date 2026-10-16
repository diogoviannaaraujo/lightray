use anyhow::{ensure, Result};
use windows::{
    core::w,
    Win32::{
        Foundation::{LocalFree, HLOCAL},
        Security::Cryptography::*,
    },
};
const ENTROPY: &[u8] = b"Lightray.Windows.Pairing.v1";
fn crypt(data: &[u8], encrypt: bool) -> Result<Vec<u8>> {
    ensure!(data.len() <= 1024 * 1024, "Secret exceeds one MiB");
    unsafe {
        let input = CRYPT_INTEGER_BLOB {
            cbData: data.len() as u32,
            pbData: data.as_ptr() as *mut u8,
        };
        let entropy = CRYPT_INTEGER_BLOB {
            cbData: ENTROPY.len() as u32,
            pbData: ENTROPY.as_ptr() as *mut u8,
        };
        let mut output = CRYPT_INTEGER_BLOB::default();
        if encrypt {
            CryptProtectData(
                &input,
                w!("Lightray pairing secret"),
                Some(&entropy),
                None,
                None,
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )?;
        } else {
            CryptUnprotectData(
                &input,
                None,
                Some(&entropy),
                None,
                None,
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )?;
        }
        let result = std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec();
        // DPAPI's output contains plaintext when decrypting: clear before releasing.
        std::ptr::write_bytes(output.pbData, 0, output.cbData as usize);
        let _ = LocalFree(Some(HLOCAL(output.pbData as _)));
        Ok(result)
    }
}
pub fn protect(data: &[u8]) -> Result<Vec<u8>> {
    crypt(data, true)
}
pub fn unprotect(data: &[u8]) -> Result<Vec<u8>> {
    crypt(data, false)
}
#[cfg(test)]
mod tests {
    #[test]
    fn dpapi_roundtrip_and_tamper() {
        let bytes = super::protect(b"pairing secret").unwrap();
        assert_ne!(bytes, b"pairing secret");
        assert_eq!(super::unprotect(&bytes).unwrap(), b"pairing secret");
        let mut bad = bytes;
        bad[20] ^= 1;
        assert!(super::unprotect(&bad).is_err());
    }
}
