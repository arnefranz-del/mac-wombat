# Website preview and hosting

`Website/` contains the German homepage, the English homepage under `en/`, and the shared assets. The site serves its fonts and images locally. It has no client-side scripts or analytics.

## Preview the product pages

From the repository root:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory Website
python3 -m unittest discover -s Tests/WebsiteTests -v
```

Run the second command in another terminal, then open [German](http://127.0.0.1:8765/) or [English](http://127.0.0.1:8765/en/). The legal links in the product pages point to the established public routes. Python’s preview server does not apply Cloudflare Pages’ `_headers` rules.

## Prepare a complete Pages folder

The existing operator and hosting notices are managed by the website operator. Before any approved deployment, assemble a complete folder with the current operator-provided HTML at these paths:

| German | English |
| --- | --- |
| `impressum/index.html` | `en/legal/index.html` |
| `datenschutz/index.html` | `en/privacy/index.html` |

Store the operator files outside `Website/` and outside the public Git tree. Pass the directory that contains those paths to:

```sh
python3 Scripts/stage-website.py /path/to/operator-pages
```

This creates `build/website/` with the product pages, assets, headers, and the four operator pages copied byte for byte. It requires a new output folder and all four inputs. Preview that folder with Cloudflare Pages tooling if available, checking the four legal routes, the two homepages, the missing-page response, and the headers.

The production site uses [Cloudflare Pages Direct Upload](https://developers.cloudflare.com/pages/get-started/direct-upload/). Use the assembled folder for a maintainer-approved deployment. After publishing, compare the public homepages and assets with that folder and check HTTP status, headers, and links. Keep the previous deployment available for rollback.

## Refresh the native product images

```sh
CONFIGURATION=debug ./Scripts/build.sh
build/products.noindex/Wombat.app/Contents/MacOS/Wombat --render-release-preview build/website-images
```

Use `mac-light.png` at 840 pixels wide for `Website/assets/mac-preview.png`, resize it to 420 pixels wide for the smaller source, and use the rendered `menu-bar.png`. The preview renders the actual UI with synthetic data in memory. The social preview places the same native screenshot next to the project mark.
