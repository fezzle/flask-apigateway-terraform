terraform {
  backend "s3" {
    bucket = "<your-bucket-name>"
    key    = "<your-key-name>"
    region = "<your-region>"
  }
}