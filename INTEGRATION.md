# SALVA DOI/PMID importer — integration guide

A small, additive feature: let a logged-in user paste a **DOI** or **PMID**, fetch
the article metadata from Crossref / PubMed, and **pre-fill SALVA's existing
"new article" and "edit article" forms** for review — for both published
(`articles`) and unpublished (`unpublished_articles`) resources. The user then
saves through SALVA's normal `create`/`update` path — this feature adds **no
new write path to the database**.

## Guarantees (so review is cheap)
- **No new gems.** Uses only the Ruby stdlib (`net/http`, `json`). Runs as-is on
  the current Ruby 2.1 / Rails 3.2 stack.
- **No migration.** The `articles.doi` column already exists. PMID is resolved to
  a DOI when PubMed provides one (it usually does); no `pmid` column is required.
- **No new DB write path.** The importer only *pre-fills the form*; saving stays on
  the existing, tested `create`/`update` actions, so all current validations, the
  `user_articles` author link, `registered_by_id`, and the 5-selected-articles
  rule continue to apply unchanged.
- **Behind existing auth.** The new action lives inside the authenticated
  `ArticlesController` / `UnpublishedArticlesController`.
- **Rollback = revert the branch.** Nothing is destructive.

## Files in this package
```
lib/salva/metadata_import.rb                 # pure normaliser: Crossref/PubMed JSON -> Article-form hash
lib/salva/metadata_fetcher.rb                # thin HTTP client (stdlib) -> parsed JSON
lib/salva/doi_pmid_importer.rb               # shared #prefill action, included by both controllers below
app/views/shared/_prefill_import.html.haml   # the DOI/PMID form box, rendered from 4 views
spec/lib/metadata_import_spec.rb             # offline, DB-free specs for the normaliser
spec/fixtures/crossref/*.json                # saved API responses -> deterministic tests
spec/fixtures/pubmed/*.json
config/eutils.yml.example                    # optional NCBI politeness (PMID only)
config/initializers/eutils.rb                # loads eutils.yml into EUTILS_CONFIG, if present (optional)
```
Copy `lib/salva/*`, `spec/**`, and `app/views/shared/_prefill_import.html.haml`
into the matching paths in the app tree (they follow the existing `lib/salva/`,
`spec/`, and `app/views/shared/` conventions). `config/initializers/eutils.rb`
is safe to copy as-is even if you skip PMID support — it falls back to `{}`
when `config/eutils.yml` doesn't exist. Copy `config/eutils.yml.example` to
`config/eutils.yml` (and edit it) only if you want PMID politeness settings.

`lib/salva/doi_pmid_importer.rb` defines `Salva::DoiPmidImporter`, a module
mixed into both `ArticlesController` and `UnpublishedArticlesController` (see
below). **It is not optional** — the controllers `include` it and will raise
`NameError: uninitialized constant Salva::DoiPmidImporter` on any request if
it's missing.

## Run the tests
The normaliser specs need no database and no running app:
```
bundle exec rspec spec/lib/metadata_import_spec.rb
```
(They only `require` the plain Ruby file, so they also run under a bare Ruby with
`gem install rspec` on any machine — handy for review outside the server.)

## The only changes to existing code

Four things: one routes block, two controllers, four views, and a small
stylesheet tweak. Below is the actual diff against `master`, not a sketch —
this is what was smoke-tested end to end in the dev container.

**1. Routes** — `config/routes/base.rb`. Adds `prefill` as both a collection
action (`GET /articles/prefill?doi=...`, for the "new" form) and a member
action (`GET /articles/:id/prefill?doi=...`, so the "edit" form can re-fetch
metadata onto an existing record) — for both `articles` and
`unpublished_articles`. **Must be declared before** the
`publication_resources_for :articles, :unpublished_articles, ...` line below
it, otherwise that block's generic `GET /articles/:id` (`#show`) route matches
`"prefill"` as an `:id` first and this route never gets reached:
```ruby
# DOI/PMID importer: GET /<resource>/prefill?doi=... or ?pmid=... (new article)
# and GET /<resource>/:id/prefill?doi=...&pmid=... (re-fetch metadata onto an
# existing article being edited). Both map to the resource's #prefill action.
# Must be declared before the :articles/:unpublished_articles resources below,
# otherwise their GET /<resource>/:id (#show) route matches "prefill" as an :id first.
[:articles, :unpublished_articles].each do |resource_name|
  resources resource_name, :only => [] do
    get :prefill, :on => :collection
    get :prefill, :on => :member
  end
end
```

**2. `app/controllers/articles_controller.rb`** — require the three `lib/salva`
files (classic autoloading doesn't resolve them from inside a class body),
mix in the shared `#prefill` action, add a duplicate-DOI guard to `create`,
and define the three hooks the module needs:
```ruby
require Rails.root.to_s + '/lib/salva/metadata_fetcher'
require Rails.root.to_s + '/lib/salva/metadata_import'
require Rails.root.to_s + '/lib/salva/doi_pmid_importer'

class ArticlesController < PublicationController
  include Salva::DoiPmidImporter

  defaults :user_role_class => :user_articles, :resource_class_scope => :published

  def create
    if params['article']['doi'].present? && (dupe = Article.where(:doi => params['article']['doi']).first)
      redirect_to(edit_article_path(dupe), :alert => 'Ese DOI ya existe en SALVA — estás viendo el artículo existente') and return
    end
    # ...existing create body unchanged...
  end

  private

  def prefill_new_path
    new_article_path
  end

  def prefill_edit_path(article)
    edit_article_path(article)
  end

  def prefill_default_articlestatus_id
    Articlestatus.find_by_name('Publicado').id
  end
end
```

**3. `app/controllers/unpublished_articles_controller.rb`** — same pattern.
The only difference is `prefill_default_articlestatus_id` returns `nil`
(unpublished articles don't get a status pre-selected by the importer):
```ruby
require Rails.root.to_s + '/lib/salva/metadata_fetcher'
require Rails.root.to_s + '/lib/salva/metadata_import'
require Rails.root.to_s + '/lib/salva/doi_pmid_importer'

class UnpublishedArticlesController < PublicationController
  include Salva::DoiPmidImporter

  defaults :user_role_class => :user_articles, :resource_class => Article, :collection_name => 'articles',
           :instance_name => 'article', :resource_class_scope => :unpublished

  def create
    if params['article']['doi'].present? && (dupe = Article.where(:doi => params['article']['doi']).first)
      redirect_to(edit_unpublished_article_path(dupe), :alert => 'Ese DOI ya existe en SALVA — estás viendo el artículo existente') and return
    end
    set_user_in_role_class!
    build_resource.registered_by_id = current_user.id
    create! { collection_url }
  end

  private

  def prefill_new_path
    new_unpublished_article_path
  end

  def prefill_edit_path(article)
    edit_unpublished_article_path(article)
  end

  def prefill_default_articlestatus_id
    nil
  end
end
```

The shared `#prefill` action itself (`lib/salva/doi_pmid_importer.rb`, shipped
in this package — nothing to add here) fetches by DOI or PMID, guards against
a duplicate DOI (redirecting to the existing record, unless that record *is*
the one currently being edited), matches an **existing** journal by ISSN then
lower-cased name (never auto-creates one), pre-fills `@article`, and re-renders
`:new` or `:edit` depending on whether `params[:id]` was given.

**4. Views** — one line added to each of the four new/edit templates for
`articles` and `unpublished_articles`, rendering the shared partial with the
right prefill URL for that context:
```haml
= render :partial => '/shared/prefill_import', :locals => { :url => prefill_articles_path }              # articles/new.html.haml
= render :partial => '/shared/prefill_import', :locals => { :url => prefill_article_path(@article) }     # articles/edit.html.haml
= render :partial => '/shared/prefill_import', :locals => { :url => prefill_unpublished_articles_path }          # unpublished_articles/new.html.haml
= render :partial => '/shared/prefill_import', :locals => { :url => prefill_unpublished_article_path(@article) } # unpublished_articles/edit.html.haml
```

**5. Stylesheet** — `app/assets/stylesheets/base.sass`. Restyles the existing
`.notice`/`.alert` flash classes as bordered boxes (previously bare colored
text) and adds a `.prefill-import-button` class used by the partial's submit
button. Purely cosmetic — safe to skip or adjust to house style if you'd
rather not touch shared CSS:
```sass
.notice
  color: #2c662d
  background-color: #eaf6ea
  border: 1px solid #2c662d
  border-radius: 4px
  padding: 8px 12px
  margin-bottom: 10px
  font-weight: bold

.alert
  color: #a33
  background-color: #fbeaea
  border: 1px solid #a33
  border-radius: 4px
  padding: 8px 12px
  margin-bottom: 10px
  font-weight: bold

.prefill-import-button
  color: #fff
  background-color: #0088bb
  border: 1px solid #006a91
  border-radius: 4px
  padding: 6px 14px
  cursor: pointer

  &:hover
    background-color: #006a91
```

**Optional config load** — `config/initializers/eutils.rb` (shipped in this
package, copy as-is) loads `config/eutils.yml` into `EUTILS_CONFIG`, falling
back to `{}` if the file is absent:
```ruby
EUTILS_CONFIG = begin
  YAML.load_file(Rails.root.join('config', 'eutils.yml'))[Rails.env] || {}
rescue Errno::ENOENT
  {}
end
```

## Decisions only you (the admin/librarians) should make
1. **Journal resolution.** This package **matches existing journals only** and
   never auto-creates one, because `Journal` requires `mediatype_id` and
   `country_id` (absent from article metadata) and firing `notify_to_librarian`
   on every import would spam the librarian. When no journal matches, the form is
   pre-filled with everything *except* the journal and the user picks/creates it
   through SALVA's normal journal workflow. If you prefer a different policy, that
   logic lives entirely in `find_existing_journal` in `doi_pmid_importer.rb`.
2. **"Publicado" status id.** The code resolves it by name
   (`Articlestatus.find_by_name('Publicado')`) on purpose: the model scopes use
   `articlestatus_id = 3`, but `db/data/articlestatuses.csv` lists "Publicado" 4th.
   Please confirm the intended id; resolving by name is safe either way.
   Unpublished-article imports leave `articlestatus_id` unset entirely
   (`prefill_default_articlestatus_id` returns `nil` in that controller).
3. **Published subclass.** Imports are created as base `Article` (status
   Publicado, for the published-articles path). If you want them as
   `PublishedArticle`, note that subclass also requires `pages`, `num`, and
   `month`, which some records lack — handle the missing-field case before
   switching.
4. **Author string format.** `authors` is free text. This package emits
   `"Family, Given; Family, Given"`. Adjust `crossref_authors` / `pubmed_authors`
   in `metadata_import.rb` to match your house style, then update the spec.
5. **Duplicate-DOI guard runs twice.** Once inside `#prefill` (redirects to the
   existing record's edit page if the fetched DOI is already in SALVA and
   isn't the record currently being edited), and once inside each `create`
   action (redirects to the existing record if a user submits a DOI that
   collides, even without having used the importer). Both are read-only checks
   against `Article.where(:doi => ...)` — no new write path.

## Notes
- **Rate limits.** Crossref: be polite via the `User-Agent` mailto (already set).
  NCBI: ≤3 req/s without a key, ≤10 with one; set `tool`/`email` (and optional
  `api_key`) in `config/eutils.yml`.
- **Network.** The app server needs outbound HTTPS to `api.crossref.org` and
  `eutils.ncbi.nlm.nih.gov`.
