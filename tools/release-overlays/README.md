# Independently published Sessions packages

Source manifests use sibling paths for same-commit development. Release
manifests replace those paths with exact immutable archive URLs and Zig hashes.
Do not rewrite the workspace's dependency graph to publish a package.

From a clean, tested source commit, run:

    tools/package-release PACKAGE COMMIT OUTPUT_DIRECTORY

Package and publication order: server-protocol, server-client, then
server-client-render. The archive is one module's tracked source with the
matching release manifest; never a snapshot of the whole workspace.
The tool refuses to overwrite an archive or distribute a sibling path.
Publication tags add a release revision without changing the package version.

Qualify extracted archives and an external consumer before attaching each
immutable asset to its prerelease tag. Record the resulting Zig hash and
SHA-256; a change requires a new release revision.
