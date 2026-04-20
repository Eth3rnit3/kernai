# Releasing Kernai

Kernai ships on [rubygems.org](https://rubygems.org/gems/kernai). The
release flow is fully driven by `bundler/gem_tasks` with a mandatory
MFA prompt (`rubygems_mfa_required` is set on the gemspec).

## One-time setup

1. Create a rubygems.org account and enable MFA.
2. Generate an API key with at least the `push_rubygem` scope:
   <https://rubygems.org/profile/api_keys>
3. Write the key to `~/.gem/credentials` (rubygems-cli-compatible
   format):

   ```
   ---
   :rubygems_api_key: rubygems_XXXX...
   ```

   `chmod 0600 ~/.gem/credentials`.

   (For CI: set the `GEM_HOST_API_KEY` env var on the runner.)

## Cutting a release

1. Make sure `main` is clean and green:

   ```sh
   bundle exec rake test
   bundle exec rubocop
   ```

2. Bump `lib/kernai/version.rb` following SemVer.
3. Write a `CHANGELOG.md` entry for the new version — keep the
   `## [Unreleased]` block if there's pending follow-up work.
4. Commit:

   ```sh
   git commit -am "chore: bump version to vX.Y.Z"
   ```

5. Push the commit to `main`:

   ```sh
   git push origin main
   ```

6. Tag, build and push in one shot:

   ```sh
   bundle exec rake release
   ```

   This task, provided by `bundler/gem_tasks`:
   - verifies the tree is clean,
   - creates the annotated tag `vX.Y.Z`,
   - pushes the tag to `origin`,
   - builds `pkg/kernai-X.Y.Z.gem`,
   - uploads it to rubygems.org (you'll get an MFA prompt).

## Sanity checks after publish

```sh
gem info kernai --remote   # confirms the new version is live
gem install kernai          # end-to-end verification
```

## Yanking

Only yank as a last resort (silent dependency breakage):

```sh
gem yank kernai -v X.Y.Z
```

Prefer a patch release with a fix.
