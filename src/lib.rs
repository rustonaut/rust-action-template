#[cfg(test)]
mod tests {
    #[test]
    fn it_works() {
        assert_eq!(2 + 2, 4);
    }

    #[cfg(feature = "yay")]
    #[test]
    fn yay_test() {}

    #[cfg(feature = "nay")]
    #[test]
    fn nay_test() {}
}
