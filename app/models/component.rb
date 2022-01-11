# frozen_string_literal: true

# Components are home to a collection of Rules.
class Component < ApplicationRecord
  include RuleConstants
  include ImportConstants
  include ExportConstants
  include ActionView::Helpers::TextHelper

  attr_accessor :skip_import_srg_rules

  amoeba do
    include_association :rules
    include_association :additional_questions
    set released: false
    set rules_count: 0

    customize(lambda { |original_component, new_component|
      # There is unfortunately no way to do this at a lower level since the new component isn't
      # accessible until amoeba is processing at this level
      new_component.additional_questions.each do |question|
        question.additional_answers.each do |answer|
          answer.rule = new_component.rules.find { |r| r.rule_id == answer.rule.rule_id }
        end
      end

      # Cloning the habtm relationship just doesn't work here since it tries to create a new rule
      # and doesn't intelligently link to the existing rule. This code loops over every rules satisfies
      # and uses the "rule_id" to recreate the same linking relationships that existed on the original_component.
      original_component.rules.each do |orig_rule|
        orig_rule.satisfies.each do |orig_satisfies|
          # By waiting until the loop to find the new rule it helps eliminte unnecessary finds.
          new_rule = new_component.rules.find { |r| r.rule_id == orig_rule.rule_id }
          new_rule_satisfies = new_component.rules.find { |r| r.rule_id == orig_satisfies.rule_id }
          new_rule.satisfies << new_rule_satisfies
        end
      end
    })
  end

  audited except: %i[id admin_name admin_email memberships_count created_at updated_at], max_audits: 1000
  has_associated_audits

  belongs_to :project, inverse_of: :components
  belongs_to :based_on,
             lambda {
               select(:srg_id, :title, :version)
             },
             class_name: :SecurityRequirementsGuide,
             foreign_key: 'security_requirements_guide_id',
             inverse_of: 'components'
  has_many :rules, dependent: :destroy
  belongs_to :component, class_name: 'Component', inverse_of: :child_components, optional: true
  has_many :child_components, class_name: 'Component', inverse_of: :component, dependent: :destroy
  has_many :memberships, -> { includes :user }, inverse_of: :membership, as: :membership, dependent: :destroy
  has_one :component_metadata, dependent: :destroy

  has_many :additional_questions, dependent: :destroy

  accepts_nested_attributes_for :rules, :component_metadata, :additional_questions, allow_destroy: true

  after_create :import_srg_rules

  validates_with PrefixValidator
  validates :prefix, :based_on, presence: true
  validate :associated_component_must_be_released,
           :rules_must_be_locked_to_release_component,
           :cannot_unrelease_component,
           :cannot_overlay_self

  def as_json(options = {})
    methods = (options[:methods] || []) + %i[releasable additional_questions]
    super(options.merge(methods: methods)).merge(
      {
        based_on_title: based_on.title,
        based_on_version: based_on.version
      }
    )
  end

  # Fill out component based on spreadsheet
  def from_spreadsheet(spreadsheet)
    self.skip_import_srg_rules = true
    # Parse the spreadsheet and extract data from the first sheet. Include headers so data is of the form
    # {VulDiscussion: 'Value', SRG ID: 'Value', etc...}
    parsed = Roo::Spreadsheet.open(spreadsheet).sheet(0).parse(headers: true).drop(1)
    # Since the component isn't saved yet, calling `based_on` here returns the wrong information
    srg_rules = SecurityRequirementsGuide.find(security_requirements_guide_id).srg_rules

    missing_headers = REQUIRED_MAPPING_CONSTANTS.values - parsed.first.keys
    unless missing_headers.empty?
      errors.add(:base, "The following required headers were missing #{missing_headers.join(', ')}")
      return
    end

    missing_srg_ids = parsed.map { |row| row[IMPORT_MAPPING[:srg_id]] } - srg_rules.map(&:version)
    unless missing_srg_ids.empty?
      errors.add(:base, 'The following required SRG IDs were missing from the selected SRG '\
                        "#{truncate(missing_srg_ids.join(', '), length: 300)}. "\
                        'Please remove these rows or select a different SRG and try again.')
      return
    end

    # Calculate the prefix (which will need to be removed from each row)
    possible_prefixes = parsed.collect { |row| row[IMPORT_MAPPING[:stig_id]] }.reject(&:blank?)
    if possible_prefixes.empty?
      errors.add(:base, 'No STIG prefixes were detected in the file. Please set any STIGID '\
                        'in the file and try again.')
      return
    else
      self.prefix = possible_prefixes.first[0, 7]
    end

    self.rules = parsed.map do |row|
      srg_rule = srg_rules.find { |rule| rule.version == row[IMPORT_MAPPING[:srg_id]] }
      # Clone existing SRGRule. This is setup in srg_rule.rb to automatically create a Rule from the result of a dup.
      r = srg_rule.amoeba_dup

      # Remove the prefix and remove any non-digits
      r.rule_id = row[IMPORT_MAPPING[:stig_id]]&.sub(prefix, '')&.delete('^0-9')
      r.title = row[IMPORT_MAPPING[:title]]
      r.fixtext = row[IMPORT_MAPPING[:fixtext]]
      r.artifact_description = row[IMPORT_MAPPING[:artifact_description]]
      r.status_justification = row[IMPORT_MAPPING[:status_justification]]
      r.vendor_comments = row[IMPORT_MAPPING[:vendor_comments]]
      # Get status with the case ignored. If none is found then fall back to the default status
      status_index = STATUSES.find_index { |item| item.casecmp(row[IMPORT_MAPPING[:status]]).zero? }
      r.status = status_index ? STATUSES[status_index] : STATUSES[0]
      # Severities are provided in the spreadsheet in the form CAT I II or III, however they are
      # stored in vulcan in 'low', 'medium', 'high'. If the spreadsheet value cannot be mapped then
      # fall back to the default from the SRG
      severity = SEVERITIES_MAP.invert[row[IMPORT_MAPPING[:rule_severity]].upcase]
      r.rule_severity = severity if severity
      r.srg_rule_id = srg_rule.id

      disa_rule_description = r.disa_rule_descriptions.first
      disa_rule_description.vuln_discussion = row[IMPORT_MAPPING[:vuln_discussion]]

      check = r.checks.first
      check.content = row[IMPORT_MAPPING[:check_content]]

      r
    end
  end

  # Helper method to extract data from Component Metadata
  def metadata
    component_metadata&.data
  end

  ##
  # Helper to get the memberships associated with the parent project
  #
  # Excludes users that already have permissions on the component
  # because we can assume that those component permissions are greater
  # than those on the project for that user.
  def inherited_memberships
    project.memberships.where.not(user_id: memberships.pluck(:user_id))
  end

  def update_admin_contact_info
    admin_members = admins
    admin_component_membership = admin_members.select { |member| member.membership_type == 'Component' }
    admin_project_membership = admin_members.select { |member| member.membership_type == 'Project' }

    if admin_component_membership.present?
      self.admin_name = admin_component_membership.first.name
      self.admin_email = admin_component_membership.first.email
    elsif admin_project_membership.present?
      self.admin_name = admin_project_membership.first.name
      self.admin_email = admin_project_membership.first.email
    else
      self.admin_name = nil
      self.admin_email = nil
    end
    save if admin_name_changed? || admin_email_changed?
  end

  ##
  # Get information for users that have admin permission on the component
  #
  # Priority:
  # - admin on the component itself
  # - admin on the owning project
  # - `nil`
  def admins
    Membership.where(
      membership_type: 'Component',
      membership_id: id,
      role: 'admin'
    ).or(
      Membership.where(
        membership_type: 'Project',
        membership_id: project_id,
        role: 'admin'
      )
    ).eager_load(:user).select(:user_id, :name, :email, :membership_type)
  end

  def releasable
    # If already released, then it cannot be released again
    return false if released_was

    # If all rules are locked, then component may be released
    rules.where(locked: false).size.zero?
  end

  def duplicate(new_version: nil, new_prefix: nil)
    new_component = amoeba_dup
    new_component.version = new_version if new_version
    new_component.prefix = new_prefix if new_prefix
    new_component.skip_import_srg_rules = true
    new_component
  end

  # Benchmark: parsed XML (Xccdf::Benchmark.parse(xml))
  def from_mapping(srg)
    benchmark = srg.parsed_benchmark
    srg_rules = srg.srg_rules.select(:id, :rule_id).map { |rule| [rule.rule_id, rule.id] }.to_h
    rule_models = benchmark.rule.each_with_index.map do |rule, idx|
      Rule.from_mapping(rule, id, idx + 1, srg_rules)
    end
    # Examine import results for failures
    success = Rule.import(rule_models, all_or_none: true, recursive: true).failed_instances.blank?
    if success
      Component.reset_counters(id, :rules_count)
      reload
    else
      errors.add(:base, 'Some rules failed to import successfully for the component.')
    end
    success
  rescue StandardError => e
    message = e.message[0, 50]
    message += '...' if e.message.size >= 50
    errors.add(:base, "Encountered an error when importing rules from the SRG: #{message}")
    false
  end

  def largest_rule_id
    # rule_id is a string, convert it to a number and then extract the current highest number.
    if id.nil?
      rules.collect { |rule| rule.rule_id.to_i }.max
    else
      Rule.connection.execute("SELECT MAX(TO_NUMBER(rule_id, '999999')) FROM base_rules
                              WHERE component_id = #{id}")&.values&.flatten&.first&.to_i || 0
    end
  end

  def prefix=(val)
    self[:prefix] = val&.upcase
  end

  ##
  # Available members for a component are:
  # - not an admin on the project (due to equal or lesser permissions constraint)
  # - not already memebers of the component
  def available_members
    exclude_user_ids = Membership.where(
      membership_type: 'Project',
      membership_id: project_id,
      role: 'admin'
    ).or(
      Membership.where(
        membership_type: 'Component',
        membership_id: id
      )
    ).pluck(:user_id)
    User.where.not(id: exclude_user_ids).select(:id, :name, :email)
  end

  def csv_export
    ::CSV.generate(headers: true) do |csv|
      csv << ExportConstants::DISA_EXPORT_HEADERS
      rules.eager_load(:reviews, :disa_rule_descriptions, :rule_descriptions, :checks, :additional_answers, :satisfies,
                       :satisfied_by, srg_rule: %i[disa_rule_descriptions rule_descriptions checks])
           .order(:version, :rule_id).each do |rule|
        csv << rule.csv_attributes
      end
    end
  end

  private

  def import_srg_rules
    # We assume that we will automatically add the SRG rules within the transaction of the inital creation
    # if the `component_id` is `nil` and if `security_requirements_guide_id` if present
    return unless component_id.nil? && security_requirements_guide_id.present?

    # Break early if the `skip_import_srg_rules` has been set to a true value
    return if skip_import_srg_rules

    # Break early if all rules imported without any issues
    return if from_mapping(SecurityRequirementsGuide.find(security_requirements_guide_id))

    raise ActiveRecord::RecordInvalid, self
  end

  def cannot_overlay_self
    # Break early if the component is not an overlay or if `id != component_id`
    return if component_id.nil? || id != component_id

    errors.add(:component_id, 'cannot overlay itself')
  end

  def cannot_unrelease_component
    # Error if component was released and has been changed to released = false
    return unless released_was && !released

    errors.add(:base, 'Cannot unrelease a released component')
  end

  def associated_component_must_be_released
    # If this isn't an imported component, then skip this vaildation
    return if component_id.nil? || component.released

    errors.add(:base, 'Cannot overlay a component that has not been released')
  end

  # All rules associated with the component should be in a locked state in order
  # for the component to be released.
  def rules_must_be_locked_to_release_component
    # If rule is not released, then skip this validation
    return if !released || (released && released_was == true)

    # If rule is releasable, then this validation passes
    return if releasable

    errors.add(:base, 'Cannot release a component that contains rules that are not yet locked')
  end
end
