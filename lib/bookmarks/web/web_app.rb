require 'sinatra'
require 'uri'

module Bookmarks
	class LoginScreen < Sinatra::Base
		enable :sessions

		get '/login' do
			redirect '/' if session[:user]
			haml :login
		end

		post '/login' do
			user = User.authenticate(params[:user], params[:password])
			if user
				session[:user] = user.id
				redirect session[:intented_url] || '/'
				session[:intented_url] = nil
			else
				redirect '/login'
			end
		end

		get '/logout' do
			session[:user] = nil
			redirect '/'
		end

		get '/register' do
			redirect '/' if session[:user]
			haml :register
		end

		post '/register' do
			begin
				new_user = User.create!(params)
				session[:user] = new_user.id
				redirect '/'
			rescue => e
				puts e
				redirect '/register'
			end
		end
	end

	class WebApp < Sinatra::Base
		use LoginScreen

		before do
			unless request.path =~ /^\/(api|register)/
				unless session[:user]
					unless request.path =~ /favicon/
						session[:intented_url] = request.url
					end
					redirect '/login'
				end
			end
		end

		def get_user
			User.find_by_id(session[:user])
		end

		def get_user_by_api_key(key)
			Token.find_by_key!(key).user
		end

		def get_list(list_id)
			list = List.find_by_id!(list_id)

			# Check if user is subscribed to list
			raise 'Access denied' unless list.users.include?(get_user)
			list
		end

		def get_tags(title)
			title.scan(/@(\w+)/).map(&:first).map do |tag|
				Tag.find_by_name(tag) || Tag.create!(:name => tag)
			end
		end

		def remove_tags(title, tags)
			tags.map(&:name).each { |tag| title.sub! /@#{tag}/, ''}
			title.strip
		end

		get '/' do
			haml :overview, :locals => {
				:user => get_user
			}
		end

		get '/user' do
			haml :user, :locals => {
				:user => get_user
			}
		end

		post '/user' do
			begin
				user = get_user
				user.update_attributes!(
					:username => params[:username],
					:email => params[:email]
				)
				if params[:passphrase] && !params[:passphrase].empty?
					user.update_attributes!(
						:passphrase => params[:passphrase],
						:passphrase_confirmation => params[:passphrase_confirmation]
					)
				end
				redirect '/'
			rescue => e
				p e
e				redirect '/user'
			end
		end

		get '/new_list' do
			new_list = get_user.lists.create :title => 'New list'
			haml :partial_list, :layout => false, :locals => {
				:list => new_list
			}
		end

		get '/list/:id' do
			begin
				list = get_list(params[:id])
				haml :partial_list, :layout => false, :locals => {
					:list => list
				}
			rescue => e
				400
			end
		end

		delete '/list/:id' do
			begin
				list = get_list(params[:id])
				list.users.delete(get_user)
				list.delete if list.users.empty?
				200
			rescue => e
				p e
				400
			end
		end

		post '/list/:id' do
			begin
				list = get_list(params[:id])
				list.update_attributes :title => params[:title]
				"OK"
			rescue => e
				400
			end
		end

		post '/bookmark/new' do
			begin
				list = get_list(params[:list])

				new_bookmark = list.bookmarks.create :title => 'New bookmark', :url => 'http://www.google.de'
				haml :partial_bookmark, :layout => false, :locals => {
					:bookmark => new_bookmark
				}
			rescue => e
				p e
				400
			end
		end

		get '/bookmarks/quick_new' do
			haml :quick_new, :locals => { 
				:user => get_user,
				:title => params[:title] || 'New bookmark',
				:url => params[:url] || 'http://',
				:list_id => params[:list]
			}
		end

		post '/bookmarks/quick_new' do
			list = get_list(params[:list])
			title = params[:title]
			tags = get_tags(title)
			title = remove_tags(title, tags)

			new_bookmark = list.bookmarks.create! :title => title, :url => params[:url]
			new_bookmark.tags = tags
			new_bookmark.save!
			redirect '/'
		end

		delete '/bookmark/:id' do
			begin
				Bookmark.find_by_id(params[:id]).delete
				"OK"
			rescue => e
				400
			end
		end

		post '/bookmark/:id' do
			begin
				bookmark = Bookmark.find_by_id(params[:id]);

				# Check if bookmark belongs to user
				raise 'Access denied' unless bookmark.list.users.include? get_user

				title = params[:title]
				tags = get_tags(title)
				bookmark.tags = tags
				title = remove_tags(title, tags)

				bookmark.update_attributes! :title => title, :url => params[:url]
				haml :partial_bookmark, :layout => false, :locals => { :bookmark => bookmark }
			rescue => e
				p e
				400
			end
		end

		get '/lists/sharing/:id' do
			begin
				list = get_list(params[:id])
				haml :partial_sharing, :layout => false, :locals => { :list => list }
			rescue => e
				400
			end
		end

		get '/lists/sharing/:list_id/add' do
			begin
				list = get_list(params[:list_id])
				user = nil

				if params[:user_id]
					user = User.find_by_id!(params[:user_id])

					# Check if users are sharing already
					raise 'No friends' unless get_user.shares_with?(user)
				else
					user = User.find_by_email!(params[:user_email])
				end

				raise 'Cannot add yourself' if user == get_user

				list.users << user
				list.save!
				haml :partial_sharing_user, :layout => false, :locals => { :user => user }
			rescue => e
				400
			end
		end

		delete '/lists/sharing/:list_id/user/:user_id' do
			begin
				list = get_list(params[:list_id])

				# Check if user wants to delete himself
				# This also avoids fully unsubscribed lists in this step
				raise 'Cannot delete yourself' if params[:user_id].to_i == get_user.id

				list.users.delete(User.find_by_id!(params[:user_id]))
				"OK"
			rescue => e
				400
			end
		end

		post '/api/username/check' do
			begin
				User.find_by_username!(params[:username]);
				200
			rescue => e
				400
			end
		end

		get '/tokens/new' do
			begin
				new_token = get_user.tokens.create!
				haml :partial_token, :layout => false, :locals => {
					:token => new_token
				}
			rescue => e
				400
			end
		end

		delete '/tokens/:id' do
			begin
				token = Token.find_by_id(params[:id])

				# Check if token belongs to user
				raise 'Access denied' unless token.user == get_user

				token.delete
				"OK"
			rescue => e
				400
			end
		end

		get '/api/bookmarks/add' do
			begin
				# Find the user
				user = get_user_by_api_key(params[:token])

				# Get the list
				list = params[:list] || user.lists.first
				raise 'No list' unless list

				# Add bookmark
				list.bookmarks.create! :title => params[:title], :url => params[:url]
				"OK"
			rescue => e
				400
			end
		end
	end
end