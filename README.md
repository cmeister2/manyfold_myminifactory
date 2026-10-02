# MyMiniFactory for Manyfold

Import your MyMiniFactory library into Manyfold, link existing models, and sync metadata and images.

## Install

Requires Manyfold 0.146.0 or newer. Importing and linking require administrator access.

1. Download `manyfold_myminifactory.zip` from the [latest release](https://github.com/cmeister2/manyfold_myminifactory/releases/latest).
2. Upload it under **Settings > Plugins**, then restart Manyfold. Keep the ZIP filename unchanged when installing updates.
3. Set your MyMiniFactory API key under **Settings > Integrations**. Create a Manyfold library if you do not have one.

See Manyfold's [plugin installation guide](https://manyfold.app/sysadmin/plugins) for plugin directory setup.

## Import your library

1. Sign in to [MyMiniFactory](https://www.myminifactory.com/library) in your browser.
2. Open the [library API page](https://www.myminifactory.com/api/data-library/objectPreviews).
3. Copy the complete JSON response.
4. In Manyfold, open **Providers > MyMiniFactory > Import**, paste the JSON, and select **Save**.

The import saves library records in the database. Duplicate MyMiniFactory IDs are merged; subsequent imports update existing records and retain entries absent from the new JSON.

## Create or link models

**Status** lists imported entries and their links to Manyfold models. Choose **Create Model** on an unlinked entry to create a model in your default library and queue metadata and image sync.

For an existing Manyfold model, choose **Link to MyMiniFactory** from its menu. The page suggests fuzzy matches from your imported library. Select **Use this model**, or enter a MyMiniFactory URL or ID, then select **Link and sync**. This action appears when an API key is configured.

JSON import alone does not create Manyfold models. Creating or syncing a model imports its details and images; download its 3D model files from MyMiniFactory and import them into Manyfold separately.

## Sync creators

On the **Creators** page, choose **Link to MyMiniFactory** from a creator's menu, select one of their linked models, and choose **Link and sync**. The plugin uses that model to find the MyMiniFactory profile and sync the existing creator's name, biography, avatar, and banner. It preserves their ownership and model associations.

The action requires an API key and administrator access, a visible MyMiniFactory-linked model assigned to the creator, and no existing MyMiniFactory profile link. Once linked, use Manyfold's normal **Synchronize** action to refresh the profile.

## Provider navigation

The plugin adds MyMiniFactory to a shared **Providers** dropdown. The menu helper is bundled, so no additional plugin is required.

Other provider plugins can bundle `lib/manyfold/provider_menu.rb` unchanged and register their menu item after Rails initializes:

```ruby
require "manyfold/provider_menu"
Manyfold::ProviderMenu.register(Components::ExampleProvider::MenuItem)
```

The component supplies a class method `label` and renders a Manyfold `DropdownItem` with its own icon and route. Entries are sorted by label. Ruby loads one copy of the helper, and repeated registration creates one dropdown. An optional class method `visible?(view_context)` controls visibility for the current request; an empty menu is hidden.

Keep the shared helper API compatible across providers: Ruby uses the first bundled copy on its load path.

## Local development

With Docker Compose installed, run from the repository root:

```sh
docker compose up --build -d
```

Open <http://localhost:3214>. The container uses single-user mode and creates an administrator and a default library automatically. Data persists in the Compose volume.

After changing Ruby code or templates, reload the application with:

```sh
docker compose restart manyfold
```

## Tests

With Python 3 and Docker installed:

```sh
bin/test
```

This runs package checks, then the plugin suite against both the source tree and an extracted ZIP. It checks the version loaded by Manyfold from the packaged gemspec. Each container uses a disposable database and Redis; temporary files and containers are cleaned up afterward.

Release tooling tests require Node 24.15 or newer:

```sh
npm ci --ignore-scripts
npm run test:release
```

## Releases

Semantic-release publishes from `main` using Conventional Commits: `fix:` produces a patch release, `feat:` a minor release, and a breaking change a major release.

The source gemspec stays at `0.0.0`. The release prepare step writes the calculated version into the gemspec inside `manyfold_myminifactory.zip`.

Pull requests and manual CI runs preview the proposed release without publishing. You can run the same preview locally:

```sh
npm run release:dry-run
```

The preview uses a temporary local Git remote and needs no GitHub credentials. It analyses commits and renders release notes; release preparation and publishing run only on a push to `main`.

To build a ZIP locally with a specific version:

```sh
python3 bin/package 0.1.0
```

The archive is written to `dist/manyfold_myminifactory.zip`.
