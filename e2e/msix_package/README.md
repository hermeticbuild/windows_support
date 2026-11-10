# msix_package e2e

This e2e packs a layout into an MSIX and an APPX package with `msix_package`, from an external repository.
It unpacks both packages with makemsix and verifies that their content matches the layout byte for byte.

The `app` files are synthetic fixtures, not a real application.
`app.exe` contains every byte value from 0 to 255, so the byte-for-byte comparison detects binary corruption during packing.
`readme.txt` uses CRLF line endings, so the comparison also detects line-ending normalization.
