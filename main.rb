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
      settings.bot.api.send_message(chat_id: message['chat']['id'], text: reply, reply_to_message_id: message['message_id'], parse_mode: 'Markdown')
    end
    200
  end

  def notify(assignee, message)
    settings.bot.api.send_message(chat_id: assignee.telegram_user_id, text: message, parse_mode: 'Markdown') if assignee&.telegram_user_id
  end


  def do_something_with_text(text, username)
    reply = ''
    if greet.include? text.downcase
      reply = 'Hi Sayang 💙'
    elsif text == '/start'
      reply = 'Welcome to Point!'
    elsif text == '/issues'
      user = User.find_by_telegram_username('@' + username)
      if user
        issues = Issue.where(assignee_id: user.id)
        reply = "Haiii @#{username}, ini task-task kamu sekarang\n"
        issues.each_with_index do |issue, index|
          reply += issue_list_message(issue, index + 1)
          reply += "\n"
        end

        if issues.size >= 3
          reply += "Banyak ya? Uuuu semangat yaa, jangan lupa jaga kesehatan yaa biar ngga sakit"
        elsif issues.size > 0
          reply += "Kamu yang semangat ya, kalo rajin ntar jodohnya lancar loh"
        else
          reply += "Eehh nggaada ya? Coba tanya sama PM/APM kamu gih, siapa tau ada yang kamu bisa bantu kan"
        end
      end
    end
    reply.empty? ? text : reply
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
    "Haiii #{issue.assignee.telegram_username} \u{1F618}, task kamu yang [#{issue.jira_issue_key}](#{ENV['JIRA_URL']}/browse/#{issue.jira_issue_key}) - *#{issue.jira_issue_parent_summary}* - #{issue.jira_issue_summary} udah dipindahtanganin sama si #{issue.assigner.telegram_username} ke si #{new_assignee.telegram_username}. Silakan kontak2an sama mereka yaa, tapi jangan genit, nanti aku cemburu loh :3"
  end

  def assign_message(issue)
    "Haiii #{issue.assignee.telegram_username} \u{1F60A} (akhirnya ada alasan buat chattingan sama kamu \u{1F633}), kamu diassign issue [#{issue.jira_issue_key}](#{ENV['JIRA_URL']}/browse/#{issue.jira_issue_key}) - *#{issue.jira_issue_parent_summary}* - #{issue.jira_issue_summary} - `#{issue.jira_issue_status}` sama si #{issue.assigner.telegram_username}. Selamat bekerjaaa :3 :3"
  end

  def change_status_message(issue)
    "Haiii #{issue.assignee.telegram_username}, task kamu yang [#{issue.jira_issue_key}](#{ENV['JIRA_URL']}/browse/#{issue.jira_issue_key}) - *#{issue.jira_issue_parent_summary}* - #{issue.jira_issue_summary} - `#{issue.jira_issue_status}` sekarang statusnya udah diganti jadi #{issue.jira_issue_detail_status} sama si #{issue.assigner.telegram_username}. Selamat bekerjaaa :3 :3"
  end

  def issue_list_message(issue, index)
    "*#{index}.* [#{issue.jira_issue_key}](#{ENV['JIRA_URL']}/browse/#{issue.jira_issue_key}) - *#{issue.jira_issue_parent_summary}* - #{issue.jira_issue_summary} - status: `#{issue.jira_issue_status}`"
  end

  def find_or_create_user(jira_user_key)
    return nil if jira_user_key.nil?
    user = User.find_by_jira_user_key(jira_user_key)
    return user if user
    User.create!(
      jira_user_key: jira_user_key
    )
  end

  def greet
    ['hi', 'halo', 'hay']
  end
end
