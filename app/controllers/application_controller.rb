class ApplicationController < ActionController::Base
  protect_from_forgery

  before_filter :set_user_time_zone, :set_current_menu
  before_filter :ensure_app_domain_name!, :authenticate_user!, :match_user_account!

  helper :all
  helper_method :current_user, :current_account, :current_role, :account_admin?, :super_admin?

  private

  def current_account
    @current_account ||= \
      if request.domain(TLD_SIZE) == AppConfig[:app_domain]
        return if request.subdomain(TLD_SIZE) == 'www'
        Account.find_by_subdomain!(request.subdomain(TLD_SIZE))
      else
        SiteSetting.find_by_domain_name!(request.host).account
      end rescue render(template: 'public/404', layout: false, status: 404)
  end

  def current_role
    if current_user and current_account
      current_user.super ? Role.super : current_user.role_for(current_account)
    end
  end

  def require_account_admin!
    unless account_admin?
      flash[:warning] = "You must be an admin user to access this page"
      redirect_to after_sign_in_path_for(current_user)
    end
  end

  def require_super_admin!
    unless super_admin?
      flash[:warning] = "You have to be a super admin user to access that page"
      redirect_to after_sign_in_path_for(current_user)
    end
  end

  def match_user_account!
    extend UrlHelper
    return unless current_user
    if current_account and not current_user.authorized_for(current_account)
      flash[:warning] = "You are not authorized to access that account"
      redirect_to setup_accounts_url(host: without_subdomain)
    end
  end

  def account_user?
    current_user.try(:authorized_for, current_account)
  end

  def account_admin?
    current_role.try(:is_admin)
  end

  def super_admin?
    current_user.try :super
  end

  def redirect_and_store_location(*opts)
    if request.get?
      session[:user_return_to] = request.fullpath
    else
      session[:user_return_to] = request.referrer
    end
    redirect_to(*opts)
  end

  def set_user_time_zone
    Time.zone = current_user.time_zone if current_user
  end

  def find_site_settings
    @site_settings = current_account.try :site_setting
  end

  def version
    Rails.cache.fetch("version", :expire_in => 5.minutes) do
      if Rails.env.staging? or Rails.env.production?
        File.ctime('Gemfile')
      elsif not `git status`.blank?
        DateTime.parse `git log -1 | grep ^Date`[8..-1]
      end.to_i.to_s(base=16)
    end
  end
  helper_method :version

  # Override Devise
  def after_sign_in_path_for(user)
    extend UrlHelper
    if not user
      new_user_session_path
    elsif current_account
      dashboard_url
    else
      setup_accounts_url
    end
  end

  def after_sign_out_path_for(user)
    new_user_session_path
  end

  # Override this to change the menu
  def set_current_menu
    @current_menu = params[:controller].to_sym
    @current_sub_menu = nil
  end

  def ensure_app_domain_name!
    unless request.domain(TLD_SIZE) == AppConfig[:app_domain]
      redirect_to host: "#{current_account.subdomain}.#{AppConfig[:app_domain]}", port: request.port, status: 301
    end
  end
end
