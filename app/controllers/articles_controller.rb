class ArticlesController < ApplicationController
  before_filter :find_article, :only => [:show, :edit, :update, :destroy, :assign]
  before_filter :contributor_only!, :only => [:new, :create]

  def new
    @article = current_account.articles.build(:reference => current_account.next_article_reference)
  end

  def create
    params[:article][:assigned_from_id] = current_user.id
    @article = current_account.articles.build(params[:article].merge(:account => current_account, :author => current_user))
    if @article.save
      flash[:notice] = "Your article has been created!"
      redirect_to edit_article_path(@article)
    else
      render :action => 'new'
    end
  end

  def edit
    @article.state = "unapproved" unless current_role.is_approver
  end

  def show
    redirect_to [:edit, @article], :status => 301
  end

  def update
    params[:article][:assigned_from_id] = current_user.id
    params[:article][:state] = "unapproved"              unless current_role.is_approver
    params[:article] = {state: params[:article][:state]} unless current_role.is_contributor

    if @article.update_attributes params[:article].merge(:author => current_user)
      flash[:notice] = "Your article has been updated!"
      redirect_to edit_article_path(@article)
    else
      render :action => 'edit'
    end
  end

  def batch_update
    case params[:batch_update_action]
    when 'assign'
      if params[:article][:assigned_to_id].present?
        Article.update_all({:assigned_to_id => params[:article][:assigned_to_id], :assigned_from_id => current_user.id, :assigned_at => Time.now}, {:id => params[:article][:id], :account_id => current_account.id})
      else
        Article.update_all({:assigned_to_id => nil, :assigned_from_id => nil, :assigned_at => nil}, {:id => params[:article][:id], :account_id => current_account.id})
      end
      flash[:notice] = "Article assignment #{params[:article][:id].size > 1 ? "have" : "has"} been updated."
    when 'delete'
      Article.where(:id => params[:article][:id], :account_id => current_account.id).update_all(state: 'deleted')
      flash[:notice] = "Your selected #{params[:article][:id].size > 1 ? "articles have" : "article has"} been deleted."
    else
      flash[:error] = "Unsupported action"
    end
    redirect_to articles_path
  end

  def destroy
    if @article.update_attribute :state, 'deleted'
      flash[:notice] = "Your article has been deleted."
    else
      flash[:error] = "There was an error while trying to delete your article."
    end

    respond_to do |format|
      format.html { redirect_to articles_path }
      format.js  { render :layout => false }
    end

  end

  def assign
    unless request.get?
      if @article.update_attributes assigned_to_id: params[:article][:assigned_to_id],
                                    assigned_from_id: current_user.id
        flash[:notice] = "The article has been assigned to #{@article.assigned_to_name}."
        redirect_to articles_path
      else
        flash.now[:error] = "There is an error while trying to assign your article. Please try again."
      end
    end
  end

  def index
    sort_init 'updated_at', 'desc'
    sort_update

    cookies[:per_page] ||= 10
    if params[:per_page].to_i >= 10 && params[:per_page].to_i <= 100 && params[:per_page].to_i % 10 == 0
      cookies[:per_page] = { :value => params[:per_page].to_i, :expires => 1.year.from_now }
    end

    options = {:page => params[:page], :per_page => cookies[:per_page], :order => sort_clause, :include => [:author, :approver],
               :joins => "LEFT JOIN users ON users.id = articles.author_id LEFT JOIN users approvers_articles ON approvers_articles.id = articles.approver_id",
               :select => "articles.*, users.first_name || ' ' || users.last_name AS author_name, approvers_articles.first_name || ' ' || approvers_articles.last_name AS approver_name, articles.feedbacks_count AS votes"}

    if params[:tag]
      @articles = current_account.articles.online.tagged_with(params[:tag]).paginate(options)
    else
      @articles = current_account.articles.online.paginate(options)
    end

    respond_to do |format|
      format.html # index.html.erb
      format.xml  { render :xml => @articles }
      format.js
    end
  end

  def search
    sort_init 'updated_at', 'desc'
    sort_update

    @query = params[:q]
    @articles = Article.internal_search @query, :account_id => current_account.id, :page => params[:page], :per_page => 10, :order => sort_clause

    respond_to do |format|
      format.html # index.html.erb
      format.xml  { render :xml => @articles }
      format.js
    end
  end

  def validate_title
    render :json => {
      :permalink => Translation.generate_permalink(params[:title]), 
      :duplicate => current_account.articles.title_exists?(params[:title])
    }
  end

  private

  def find_article
    @article = current_account.articles.online.find_by_reference!(params[:id])
  end

  def set_assignment_user
    if params[:article].try(:[], :assigned_to_id)
      if params[:article][:assigned_to_id] == ''
        params[:article].merge!({
          :assigned_from_id => '',
          :assigned_at => ''
        })
      else
        if @article.assigned_to_id != params[:article][:assigned_to_id].to_i
          params[:article].merge!({
            :assigned_from_id => current_user.id,
            :assigned_at => Time.now
          })
        else
          params[:article].delete(:assigned_to_id)
        end
      end
    end
  end

  def contributor_only!
    unless current_role.is_contributor
      flash[:error] = "You do not have sufficient permission to create an article"
      @article = current_account.articles.build
      return redirect_to :action => 'index'
    end
  end
end
