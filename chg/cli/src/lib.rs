//! `chg`: the client side of the change system (design §3.4, §3.13).

pub mod contract;
pub mod exec;
pub mod output;

/// `chg --version` output: the binary version and the adapter contract it implements.
pub const VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), " (adapter contract ", "1", ")");

#[cfg(test)]
mod tests {
    #[test]
    fn version_names_the_contract() {
        assert!(super::VERSION.ends_with(&format!(
            "(adapter contract {})",
            super::contract::CONTRACT_VERSION
        )));
    }
}
