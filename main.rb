require 'dotenv/load'
require 'sinatra'
require 'telegram/bot'
require 'json'
require 'active_support/core_ext/hash'
require 'sinatra/activerecord'
require './models/issue.rb'
require './models/user.rb'

class Main < Sinatra::Base
  configure do
    set :bot, Telegram::Bot::Client.new(ENV['TELEGRAM_BOT_TOKEN'])
  end

  get '/' do
    'hello world!'
  end

  post '/issues/{id}/update' do
    issue = Issue.find_by_jira_issue_id(params[:id])

    params = JSON.parse(request.body.read).with_indifferent_access

    if issue
      if params[:changelog][:items].last[:field] == 'assignee'
        jira_user_key = params[:changelog][:items].last[:to]
        new_assignee = find_or_create_user(jira_user_key)
        notify(issue.assignee, unassign_message(issue, new_assignee))
        issue.update_attributes!(serialize_issue(params))
        notify(issue.assignee, assign_message(issue))
      elsif params[:changelog][:items].last[:field] == 'status'
        issue.update_attributes!(serialize_issue(params))
        notify(issue.assignee, change_status_message(issue))
      end
    else
      issue = Issue.create!(serialize_issue(params))
      notify(issue.assignee, assign_message(issue))
    end

    200
  end

  post '/message/{token}' do
    # raise 'Wrong Token' if params[:token] != ENV['TELEGRAM_BOT_TOKEN']
    update = JSON.parse(request.body.read)
    if update['message']
      message = update['message']
      puts message.to_s
      reply = do_something_with_text(message['text'], message['from']['username'])
      replies = format_to_messages(reply)
      replies.each_with_index do |reply, index|
        puts reply
        if index == 0
          settings.bot.api.send_message(chat_id: message['chat']['id'], text: reply, reply_to_message_id: message['message_id'], parse_mode: 'HTML', disable_web_page_preview: true) unless reply.empty?
        else
          settings.bot.api.send_message(chat_id: message['chat']['id'], text: reply, parse_mode: 'HTML', disable_web_page_preview: true) unless reply.empty?
        end
      end
    end
    200
  end

  def notify(assignee, message)
    settings.bot.api.send_message(chat_id: assignee.telegram_user_id, text: message, parse_mode: 'HTML', disable_web_page_preview: true) if assignee&.telegram_user_id
  end

  def format_to_messages(reply)
    lines_count = 10
    reply_lines = reply.split("\n")
    replies = []
    reply_text = ''
    reply_lines.each_with_index do |reply_line, index|
      reply_text += reply_line + "\n"
      if (index + 1) % lines_count == 0
        replies << reply_text
        reply_text = ''
      end
    end
    replies << reply_text if !reply_text.empty?
    replies
  end

  def do_something_with_text(text, username)
    return '' if text.nil?
    reply = ''
    text = text.split('@').first

    if greet.match text.downcase
      reply = 'Halo kak!'
    end

    if text.start_with?('/')
      if text == '/start'
        reply = 'Welcome to Point!'
      elsif text.start_with?('/issues')
        second_string = text.split(' ', 2)[1]
        all = !second_string.nil?

        user = User.find_by_telegram_username('@' + username)
        if user
          issues = Issue.where(assignee_id: user.id)
          issues = issues.reject { |issue| issue.jira_issue_status == 'Done'} unless all

          reply = "Haiii @#{username}, ini task-task #{all ? '' : 'active '}kamu sekarang\n"
          issues.each_with_index do |issue, index|
            reply += issue_list_message(issue, index + 1) + "\n"
          end

          if issues.size >= 3
            reply += "\nBanyak ya? Uuuu semangat yaa, jangan lupa jaga kesehatan yaa biar ngga sakit"
          elsif issues.size > 0
            reply += "\nKamu yang semangat ya, kalo rajin ntar jodohnya lancar loh"
          else
            reply += "\nEehh nggaada ya? Coba tanya sama PM/APM kamu gih, siapa tau ada yang kamu bisa bantu kan"
          end
        end
      elsif text == '/help'
        reply = get_available_commands
      else
        reply = ''#"Ummm aku ngga ngerti bahasa kamu nih \u{1F616}. Coba ketik /help biar kita bisa semakin memahami"
      end
    end

    reply
  end

  def serialize_issue(params)
    assignee_jira_key = params[:issue][:fields][:assignee][:key]
    assigner_jira_key = params[:user][:key]
    assignee = find_or_create_user(assignee_jira_key)
    assigner = find_or_create_user(assigner_jira_key)

    jira_issue_id = params[:issue][:id]
    jira_issue_key = params[:issue][:key]
    jira_issue_summary = params[:issue][:fields][:summary]
    jira_issue_parent_summary = params[:issue][:fields][:parent]&.[](:fields)&.[](:summary)
    jira_issue_status = params[:issue][:fields][:status][:name]
    jira_issue_detail_status = params[:issue][:fields]&.[](:customfield_10601)&.[](:value)

    {
      assignee_id: assignee&.id,
      jira_issue_id: jira_issue_id,
      jira_issue_key: jira_issue_key,
      jira_issue_summary: jira_issue_summary,
      jira_issue_parent_summary: jira_issue_parent_summary,
      jira_issue_status: jira_issue_status,
      jira_issue_detail_status: jira_issue_detail_status,
      assigner_id: assigner.id
    }
  end

  def unassign_message(issue, new_assignee)
    "Haiii #{issue.assignee&.handle} \u{1F618}, task kamu yang <a href=\"#{ENV['JIRA_URL']}/browse/#{issue.jira_issue_key}\">#{issue.jira_issue_key}</a> - <b>#{issue.jira_issue_parent_summary}</b> - #{issue.jira_issue_summary} udah dipindahtanganin sama si #{issue.assigner.handle} ke si #{new_assignee.handle}. Silakan kontak2an sama mereka yaa, tapi jangan genit, nanti aku cemburu loh :3"
  end

  def assign_message(issue)
    "Haiii #{issue.assignee&.handle} \u{1F60A} (akhirnya ada alasan buat chattingan sama kamu \u{1F633}), kamu diassign issue <a href=\"#{ENV['JIRA_URL']}/browse/#{issue.jira_issue_key}\">#{issue.jira_issue_key}<a/> - <b>#{issue.jira_issue_parent_summary}</b> - #{issue.jira_issue_summary} - <code>#{issue.jira_issue_status}</code> sama si #{issue.assigner.handle}. Selamat bekerjaaa :3 :3"
  end

  def change_status_message(issue)
    "Haiii #{issue.assignee&.handle}, task kamu yang <a href=\"#{ENV['JIRA_URL']}/browse/#{issue.jira_issue_key}\">#{issue.jira_issue_key}</a> - <b>#{issue.jira_issue_parent_summary}</b> - #{issue.jira_issue_summary} sekarang statusnya udah diganti jadi <code>#{issue.jira_issue_status}</code> sama si #{issue.assigner.handle}. Selamat bekerjaaa :3 :3"
  end

  def issue_list_message(issue, index)
    "<b>#{index}.</b> <a href=\"#{ENV['JIRA_URL']}/browse/#{issue.jira_issue_key}\">#{issue.jira_issue_key}</a> - <b>#{issue.jira_issue_parent_summary}</b> - #{issue.jira_issue_summary} - status: <code>#{issue.jira_issue_status}</code>"
  end

  def find_or_create_user(jira_user_key)
    return nil if jira_user_key.nil?
    user = User.find_by_jira_user_key(jira_user_key)
    return user if user
    User.create!(
      jira_user_key: jira_user_key
    )
  end

  def get_available_commands
    "ini nihh bahasa yang aku pahaminn:\n" +
    "<b>-</b> /issues buat liat issue-issue yang diassign ke kamu"
  end

  def greet
    /h[a-zA-Z]*/
  end
end
