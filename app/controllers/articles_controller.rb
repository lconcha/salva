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
    params['article']['user_articles_attributes'].each{ |ua|
      if ua[1]['user_id'].to_s==current_user.id.to_s and params['article']['is_selected'].to_s=='1' and User.find(current_user.id).my_selected_articles.count>5 then
        redirect_to new_article_path(params), :notice => "No está permitido tener más de 5 artículos selectos"
        return(current_user.id.to_s)
      end
    }
    set_user_in_role_class!
    build_resource.registered_by_id = current_user.id
    create! { collection_url }
  end

  def update
    params['article']['user_articles_attributes'].each{ |ua|
      if ua[1]['user_id'].to_s==current_user.id.to_s and params['article']['is_selected'].to_s=='1' and User.find(current_user.id).my_selected_articles.count>5 then
        redirect_to edit_article_path(params), :notice => "No está permitido tener más de 5 artículos selectos"
        return(current_user.id.to_s)
      end
    }
    set_user_in_role_class!
    resource.modified_by_id = current_user.id
    update! { collection_url }
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
