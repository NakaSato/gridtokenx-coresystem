use base64::{Engine as _, engine::general_purpose};

fn main() {
    let b64 = "GovEJZloMMAfmEMe6a8+qpZgNqmW/OxYRfFLOAMZU1k=";
    let bytes = general_purpose::STANDARD.decode(b64).unwrap();
    println!("{}", bs58::encode(bytes).into_string());
}
