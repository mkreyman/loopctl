//! `chg`: the client side of the change system (design §3.4, §3.13).

pub mod adapter;
pub mod check;
pub mod clone;
pub mod contract;
pub mod cover;
pub mod culprit;
pub mod doctor;
pub mod events;
pub mod exec;
pub mod gate;
pub mod gh;
pub mod git;
pub mod glob;
pub mod outbox;
pub mod output;
pub mod revert;
pub mod scratch;
pub mod shadow;
pub mod snapshot;
pub mod store;
pub mod verify;
pub mod ws;

/// `chg --version` output: the binary version, the adapter contract it implements, and the
/// commit it was built from (`build.rs`).
pub const VERSION: &str = concat!(
    env!("CARGO_PKG_VERSION"),
    " (adapter contract ",
    "1",
    ", commit ",
    env!("CHG_BUILD_SHA"),
    ")"
);

#[cfg(test)]
mod tests {
    #[test]
    fn version_names_the_contract() {
        assert!(super::VERSION.contains(&format!(
            "(adapter contract {}, commit ",
            super::contract::CONTRACT_VERSION
        )));
    }
}
