# lib/salva/doi_pmid_importer.rb
#
# Shared "prefill" action for controllers that let a user fetch Crossref/
# PubMed metadata by DOI or PMID onto an Article-backed form (new or edit).
# Nothing is saved here -- it only repopulates the form for review; saving
# still goes through the including controller's own create/update.
#
# The including controller must define three small hooks (see
# ArticlesController / UnpublishedArticlesController):
#   prefill_new_path                  -> path for a not-found redirect on a new record
#   prefill_edit_path(article)        -> path for a not-found/duplicate redirect on an existing record
#   prefill_default_articlestatus_id  -> id to pre-select, or nil to leave the status unset
module Salva
  module DoiPmidImporter
    def prefill
      opts = defined?(EUTILS_CONFIG) ? EUTILS_CONFIG.symbolize_keys : {}
      pmid = MetadataImport.clean_pmid(params[:pmid])
      raw =
        if params[:doi].present?
          msg = MetadataFetcher.crossref(params[:doi], opts)
          msg && MetadataImport.from_crossref(msg)
        elsif pmid.present?
          rec = MetadataFetcher.pubmed(pmid, opts)
          rec && MetadataImport.from_pubmed(rec)
        end

      @article = params[:id].present? ? Article.find(params[:id]) : Article.new
      fallback_path = @article.new_record? ? prefill_new_path : prefill_edit_path(@article)

      unless raw
        redirect_to(fallback_path, :alert => 'No se encontró metadata para ese DOI/PMID') and return
      end

      if raw['doi'].present? && (dupe = Article.where(:doi => raw['doi']).first) && dupe.id != @article.id
        redirect_to(prefill_edit_path(dupe), :alert => 'Ese DOI ya existe en SALVA — estás viendo el artículo existente') and return
      end

      journal = find_existing_journal(raw['issn'], raw['journal_name'])

      attrs = {
        :title      => raw['title'],
        :authors    => raw['authors'],
        :year       => raw['year'],
        :month      => raw['month'],
        :vol        => raw['vol'],
        :num        => raw['num'],
        :pages      => raw['pages'],
        :doi        => raw['doi'],
        :url        => raw['url'],
        :journal_id => (journal && journal.id)
      }
      attrs[:articlestatus_id] = prefill_default_articlestatus_id if prefill_default_articlestatus_id
      @article.attributes = attrs
      unless journal
        flash.now[:notice] =
          if raw['journal_name'].present?
            "Revisa y selecciona la revista «#{raw['journal_name']}»"
          else
            'No se encontraron datos de la revista (frecuente en pre-prints) — selecciona una manualmente'
          end
      end
      render(@article.new_record? ? :new : :edit)
    end

    private

    def find_existing_journal(issn, name)
      j = Journal.where(:issn => issn).first if issn.present?
      j ||= Journal.where('lower(name) = ?', name.to_s.downcase).first if name.present?
      j
    end
  end
end
