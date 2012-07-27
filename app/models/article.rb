# Table name: articles
#
#  id                   :integer(4)      not null, primary key
#  account_id           :integer(4)      not null
#  previous_revision_id :integer(4)
#  state                :string(255)     default("draft")
#  author_id            :integer(4)
#  approver_id          :integer(4)
#  allow_comments       :boolean(1)      default(TRUE)
#  created_at           :datetime
#  updated_at           :datetime
#  clicks               :integer(4)
#  delta                :boolean(1)      default(TRUE), not null
#  assigned_to_id       :integer(4)
#  assigned_from_id     :integer(4)
#  assigned_at          :datetime
#  next_revision_id     :integer(4)
#  discussion_id        :integer(4)
#  priority             :boolean(1)
#  article_metric_id    :integer(4)
#  reference            :string(255)
#  published_version_id :integer(4)
#  latest_version_id    :integer(4)
#  uuid                 :string(255)  
#  rating               :integer(4)
#  feedbacks_count      :integer(4)
#  exclude_from_search  :boolean(1)      default(FALSE)
#  exclude_from_faq     :boolean(1)      default(FALSE)
#  internal             :boolean(1)      default(FALSE), not null
#

class Article < ActiveRecord::Base
  belongs_to  :account
  belongs_to  :author, :class_name => "User"
  belongs_to  :approver, :class_name => "User"

  belongs_to  :assigned_to, :class_name => "User"
  belongs_to  :assigned_from, :class_name => "User"

  has_many    :article_subjects, :dependent => :destroy
  has_many    :subjects, :through => :article_subjects
  has_many    :nodes, :through => :article_subjects
  has_many    :feedbacks, :dependent => :destroy, :order => :created_at
  has_many    :versions, :class_name => "ArticleVersion", :order => :version
  has_many    :comments, :as => :commentable
  has_many    :attachments, :class_name => "::Attachment", :foreign_key => 'article_uuid', :primary_key => 'uuid', :dependent => :destroy
  has_many    :metrics

  belongs_to  :published_version, :class_name => "ArticleVersion"
  belongs_to  :latest_version, :class_name => "ArticleVersion"

  attr_accessor :preferred_locale

  acts_as_taggable_on :tags

  scope :assigned, lambda{ |id| where(['assigned_to_id = ? or assigned_from_id = ?', id, id]).order('articles.assigned_at DESC') }
  scope :recently_edited, lambda{ |id| where({:author_id => id}).order('articles.assigned_at DESC').limit(10) }

  scope :online, where("articles.state != 'deleted'")
  scope :published, where("articles.state != 'deleted' AND articles.state = 'published' AND articles.published_version_id IS NOT NULL").order("priority DESC, id ASC")
  scope :internal, where("articles.internal")
  scope :external, where("NOT articles.internal")
  scope :visible_to, lambda{ |user| user.is_a?(User) ? published : published.external }
  scope :most_viewed, where({ :exclude_from_faq => false }).order("priority DESC, clicks_rolling DESC, clicks DESC").limit(10)

  before_validation :purge_blank_versions
  after_save :update_versions
  after_save :update_nodes
  after_save :increment_article_reference
  after_initialize :set_uuid
  after_create :apply_tags

  STATES = [['Draft', 'draft'], ['Awaiting Approval', 'unapproved'], ['Published', 'published'], ["Archive", "archive"]]

  validates_uniqueness_of :reference, :scope => :account_id
  validates_format_of :reference, :with => /[A-Za-z0-9]*/

  searchable do
    text :title, :boost => 3.0, :more_like_this => true
    text :published_content, :more_like_this => true
    text :content
    text :reference, :boost => 6.0
    string :title
    string :state
    string :reference
    time :updated_at
    string :author_name
    string :approver_name do
      approver_name || "Unassigned"
    end
    integer :rating
    integer :votes, :using => :feedbacks_count
    integer :clicks
    integer :published_version_id, :references => ArticleVersion
    integer :account_id, :references => Account
    integer :tag_ids, :references => ActsAsTaggableOn::Tag, :multiple => true
    boolean :exclude_from_search, :using => :exclude_from_search?
    boolean :internal
  end

  def self.public_search(keyword, opts = {})
    search do
      keywords keyword, :fields => [:title, :published_content, :reference]
      without :published_version_id, nil
      with :state, 'published'
      without :exclude_from_search, true
      without :internal
      with :account_id, opts[:account_id]
      with :tag_ids, opts[:subject_id] if opts[:subject_id]
      paginate :page => opts[:page], :per_page => (opts[:per_page] || 30) if opts[:page]
      order_by *opts[:order].downcase.split.map(&:to_sym) if opts[:order]
    end.results
  end

  def self.internal_search(keyword, opts = {})
    search do
      keywords keyword, :fields => [:title, :content, :reference]
      without :state, 'deleted'
      with :account_id, opts[:account_id]
      paginate :page => opts[:page], :per_page => (opts[:per_page] || 30) if opts[:page]
      order_by(*opts[:order].downcase.split.map{ |o| o.to_sym }) if opts[:order]
    end.results
  end

  def self.title_exists?(title) # tests for title from index
    search{ with :title, title }.results.any?
  end

  def self.find_by_reference(ref)
    where(:reference => ref[/[^-]+/]).first
  end

  def self.find_by_reference!(ref)
    find_by_reference(ref) or raise ActiveRecord::RecordNotFound
  end

  def related_articles
    more_like_this do
      without :published_version_id, nil
      with :state, 'published'
      with :account_id, account_id
      without :internal
      paginate :page => 1, :per_page => 5
      facet :tag_ids
    end.results
  end

  def author_name
    @author_name ||= author.try :name
  end

  def approver_name
    @approver_name ||= approver.try :name
  end

  def assigned_to_name
    @assigned_to_name ||= assigned_to.try(:name)
  end

  def assigned_from_name
    @assigned_from_name ||= assigned_from.try(:name)
  end
  
  before_save :check_if_assignment_happened
  def check_if_assignment_happened
    return if @saved
    self.latest_version = self.versions.last
    if assigned_to_id_changed?
      self.assigned_at = Time.now
      AssignmentMailer.assignment_notification(self.assigned_to, self, self.assigned_from).deliver if self.assigned_to
    else # revert change
      self.assigned_from_id = self.assigned_from_id_was
    end
  end

  def clicks
    self[:clicks] || 0
  end

  def status
    if state == "deleted"
      "Deleted"
    else
      STATES.rassoc(state)[0] rescue state.capitalize
    end
  end

  def title(locale = nil)
    translation(locale).title
  end

  def title=(value, locale = nil)
    translation(locale).title = value
  end

  def permalink(locale = nil)
    translation(locale).permalink
  end

  def permalink=(value, locale = nil)
    translation(locale).permalink = value
  end

  def content(locale = nil)
    translation(locale).content
  end

  def content=(value, locale = nil)
    translation(locale).content = value
  end

  def translation(locale = nil)
    locale                ||= @preferred_locale
    @translations         ||= {}
    @translations[locale] ||= latest_version.translated(locale)
  end

  # new_translations is a hash e.g. {123 => {:title => "How can I pay my bill", ...}} where 123 is the locale id
  def translations= new_translations
    @new_version = self.versions.build(:article => self, :version => (self.versions.count + 1), :translations_attributes => new_translations) if
      self.latest_version.translations != new_translations
  end

  def published_content(locale = nil)
    locale                      ||= @preferred_locale
    @published_contents         ||= {}
    @published_contents[locale] ||= self.published_version.try(:content, locale)
  end

  def tag_list
    tags_from account
  end

  def tag_list=(new_tags)
    new_tags = new_tags.select{ |tag| not tag.blank? }
    unless new_record?
      set_owner_tag_list_on account, :tags, new_tags
    else
      @new_tags = new_tags
    end
  end

  def apply_tags
    self.tag_list = @new_tags
  end

  def html_content
    require 'oozou/textile_parser'
    @html_content ||= Oozou::TextileParser.convert(content)
  end

  def refresh_rating!
    self.update_attributes :rating => (feedbacks.average(:rating).ceil rescue nil), :feedbacks_count => feedbacks.count
  end

  alias stored_latest_version latest_version
  def latest_version
    stored_latest_version or versions.build
  end

  def to_param(locale = nil)
    "#{reference}-#{permalink locale}"
  end

  def update_nodes
    # Remove unused node from the subject tree
    Node.all(:conditions => ["account_id = ? AND object_type = 'ArticleSubject' AND article_subjects.id IS NULL", account_id], :joins => "LEFT JOIN article_subjects ON article_subjects.id = nodes.object_id").each do |node|
      Node.find_by_id(node['id']).try(:destroy)
    end

    Node.update_all({ :name => title, :permalink => "articles/#{to_param}", :reference => reference }, { :id => node_ids })
    nodes.map &:update_visibility
  end

  def reset!
    update_attributes! :clicks => 0, :clicks_rolling => 0, :reset_at => DateTime.now
  end

  private

  def purge_blank_versions
    self.versions = versions.select{ |v| not v.blank? }
    true
  end

  def update_versions
    return if @saved # hack: prevents double-saving
    if @new_version
      self.latest_version = @new_version
      self.published_version = @new_version if self.state == 'published'
    else
      self.published_version = self.latest_version if self.state == 'published'
    end
    @new_version = nil
    @saved = true
    save
  end

  def check_spelling
    Spell.correct(title)
  end

  def increment_article_reference
    account.increment_article_reference(reference)
  end

  def set_uuid
    self[:uuid] ||= Digest::SHA1.hexdigest("%.10f" % Time.now.to_f)
  end
end
