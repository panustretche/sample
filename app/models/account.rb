# Table name: accounts
#
#  id                     :integer(4)      not null, primary key
#  subdomain              :string(255)
#  company                :string(255)
#  created_at             :datetime
#  updated_at             :datetime
#  state                  :string(255)     default("pending")
#  reference_prefix       :string(255)     default("")
#  reference_size         :integer(4)      default(1)
#  next_reference_id      :integer(4)      default(1)
#  case_email             :string(255)
#  case_thank_you_message :text
#  default_locale_id      :integer(4)
#

class Account < ActiveRecord::Base

  acts_as_tagger

  has_many  :roles, :dependent => :destroy
  has_many  :users, :through => :roles
  has_many  :invites
  has_one   :site_setting, :dependent => :destroy
  has_many  :articles, :dependent => :destroy
  has_many  :feedbacks, :through => :articles, :dependent => :destroy
  has_many  :subjects, :dependent => :destroy
  has_many  :nodes, :dependent => :destroy
  has_many  :attachments, :class_name => '::Attachment', :dependent => :destroy
  has_many  :case_submission_fields, :class_name => "Field", :order => :position, :dependent => :destroy
  has_many  :locales, :dependent => :destroy
  has_many  :snippets, :dependent => :destroy

  belongs_to :default_locale, :class_name => "Locale"

  accepts_nested_attributes_for :users
  accepts_nested_attributes_for :site_setting
  accepts_nested_attributes_for :case_submission_fields, :allow_destroy => true

  # Subdomain
  RESERVED_SUBDOMAINS = %w( support blog www billing help api mail developer forum )

  validates_presence_of   :subdomain
  validates_format_of     :subdomain,
                          :with => /^[A-Za-z0-9-]+$/,
                          :message => ' can only contain alphanumeric characters and dashes.',
                          :allow_blank => true
  validates_exclusion_of  :subdomain,
                          :in => RESERVED_SUBDOMAINS,
                          :message => " <strong>{{value}}</strong> is reserved and unavailable."
  validates_uniqueness_of :subdomain, :case_sensitive => false
  before_validation       :downcase_subdomain

  # End User license acceptance
  attr_accessor           :eula
  validates_acceptance_of :eula, :on => :create, :message => "must be accepted"

  # Default locale
  after_create            :ensure_default_locale_exists

	def destroy
    if self.default_locale
      self.default_locale.default_locale_for = nil
      self.default_locale = self.default_locale_id = nil
      save
    end
		super
	end

  after_create            :provide_sensible_defaults
  after_save              :ensure_root_subject_exists

  def root_node
    @root_node ||= self.nodes.find_by_parent_id(nil)
  end

  def root_subject
    root_node.try :object
  end

  def major_subjects(user = nil)
    root_node.children.just_subjects.privilege(user).collect &:object
  end

  def next_article_reference
    "#{reference_prefix}#{"%0#{reference_size.to_i}d" % next_reference_id}"
  end

  def increment_article_reference(current_reference)
    max_reference_id = articles.where("articles.reference LIKE ?", "#{reference_prefix}%").maximum(:reference)[/(\d+)/,-1] || 0
    self.update_attribute :next_reference_id, max_reference_id.to_i + 1
  end

  def to_s
    company
  end

  def self.to_options # for <select>s
    all.collect { |p| [p.company, p.id] }
  end

  private

  def downcase_subdomain
    self.subdomain.downcase! if attribute_present?("subdomain")
  end

  def provide_sensible_defaults
    case_submission_fields.create name: "Name", field_type: :first_name, position: 1, required: true
    case_submission_fields.create name: "Email", field_type: :email_address, position: 2, required: true
    create_site_setting
  end

  def ensure_root_subject_exists
    unless root_subject
      subjects.create(:parent_id => nil, :title => 'Subjects')
    end
  end

  def ensure_default_locale_exists
    if valid? and not default_locale
      en = locales.build :code => "en", :language => "English", :territory => ""
      self.update_attribute :default_locale, en
    end
  end
end
