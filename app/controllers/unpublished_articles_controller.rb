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
