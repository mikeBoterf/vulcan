# frozen_string_literal: true

# This module handles items that we use across multiple controllers
# and views throughout the application
module SlackNotificationsHelper
  include SlackNotificationFieldsHelper

  def client
    @client ||= Slack::Web::Client.new(token: Settings.slack.api_token)
  end

  def send_notification(channel, message_params)
    message = build_message(message_params)
    client.chat_postMessage(channel: channel, blocks: message)
  rescue Slack::Web::Api::Errors::ChannelNotFound => e
    Rails.logger.error "Slack channel '#{channel}' not found: #{e.message}"
  rescue Slack::Web::Api::Errors::SlackError => e
    Rails.logger.error "Slack API error: #{e.message}"
  end

  def get_slack_headers_icons(notification_type, notification_type_prefix)
    icon = case notification_type_prefix
           when 'assign', 'upload', 'create', 'approve' then ':white_check_mark:'
           when 'rename', 'update', 'request_review', 'change_visibility' then ':loudspeaker:'
           when 'remove', 'revoke', 'request_changes' then ':x:'
           end
    header_map = {
      create_component: 'Vulcan New Component Creation',
      remove_component: 'Vulcan Component Removal',
      create_project: 'Vulcan New Project Creation',
      rename_project: 'Vulcan Project Renaming',
      change_visibility: 'Vulcan Project Visibility Change',
      remove_project: 'Vulcan Project Removal',
      create_project_membership: 'New Members Added to the Project',
      update_project_membership: 'Membership Updated on the Project',
      remove_project_membership: 'Members Removed from the Project',
      create_component_membership: 'New Members Added to the Component',
      update_component_membership: 'Membership Updated on the Component',
      remove_component_membership: 'Members Removed from the Component',
      upload_srg: 'Vulcan New SRG (Security Requirement Guide) Upload',
      remove_srg: 'Vulcan SRG (Security Requirement Guide) Removal',
      assign_vulcan_admin: 'Assigning Vulcan Admin',
      remove_vulcan_admin: 'Removing Vulcan Admin',
      request_review: 'Control Review Request',
      approve: 'Control Reviewed and Locked',
      revoke_review_request: 'Revoking Review Request',
      request_changes: 'Control Changes Request'
    }
    header = header_map[notification_type.to_sym]
    [icon, header]
  end

  private

  def build_message(params)
    blocks = Slack::BlockKit.blocks do |b|
      b.section do |s|
        s.text = Slack::BlockKit::Composition::Mrkdwn.new(text: "#{params[:icon]} *#{params[:header]}*")
      end

      b.divider

      params[:fields].each do |field|
        b.section do |s|
          s.text = Slack::BlockKit::Composition::Mrkdwn.new(text: "*#{field[:label]}:* #{field[:value]}")
        end
      end

      b.divider
    end
    blocks.to_json
  end
end
