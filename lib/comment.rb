require 'pathname'
require 'store'
require 'time'
require 'fileutils'
require 'comment/renderer'

class Comment
  class NotFound < Exception; end
  class PermissionDenied < Exception; end
  class SizeLimitExceeded < Exception; end
  class MaxCommentsExceeded < Exception; end

  FILE = {
    :index   => 'index.db',
    :read    => 'read.db',
  }

  def initialize(user, group, path, config)
    @user = user
    @group = group
    @path = path
    @path = Pathname.new(@path.to_s) unless @path.is_a?(Pathname)
    @config = config
  end

  def db_index()
    return Store.new(@path + FILE[:index])
  end

  def db_read()
    return Store.new(@path + FILE[:read])
  end

  def retrieve(args)
    return [] unless File.exist?(db_index.path)
    db_index.ro.transaction do |db|
      entries = db[:entries] || []
      entries = filter_forbidden(entries)
      entries.reject!{|e| e['id'] != args[:id]} if args[:id]
      entries = entries.drop(args[:offset]) if args[:offset]
      entries = entries.take(args[:limit]) if args[:limit]
      return load_content(args[:type] || :html, entries)
    end
  end

  def add(args)
    db_index.transaction do |db|
      # new ID
      id = (db[:max_id] || 0) + 1
      raise MaxCommentsExceeded if id > (@config['max'] || 256)

      args[:id] = id
      args[:user] = @user
      args[:create] = Time.now.iso8601
      args[:acl] = args[:acl] || @config['acl'] || [ 'user', 'other' ]

      idx = index_check(args)
      content = content_check(args)

      db[:max_id] = id

      entries = db[:entries] || []
      entries.push(idx)
      db[:entries] = entries

      write_content(id, content)
    end
  end

  def edit(args)
    db_index.transaction do |db|
      entries = db[:entries] || []
      entry = entries.find{|e| e['id'] == args[:id]}
      raise NotFound unless entry
      raise PermissionDenied unless @group == :super || entry['user'] == @user

      idx = index_check(args)
      content = content_check(args)

      entry.merge!(idx)
      write_content(entry['id'], content)
    end
  end

  def delete(id)
    db_index.transaction do |db|
      entries = db[:entries] || []
      entry = entries.find{|e| e['id'] == id}
      raise NotFound unless entry
      raise PermissionDenied unless @group == :super || entry['user'] == @user

      entries = entries.reject {|e| e['id'] == id }
      db[:entries] = entries

      delete_content(id)
    end
  end

  # Deletes all content files and the index.
  def delete_all()
    raise PermissionDenied unless @group == :super
    db_index.transaction do |db|
      entries = db[:entries] || []
      entries.each {|e|
        delete_content(e['id'])
      }
      db[:entries] = []
    end
  end

  def read(id)
    raise PermissionDenied unless @group == :super || @group == :user

    db_read.transaction do |r|
      max = r[@user] || 0
      r[@user] = id if max < id
    end
  end

  def news()
    raise PermissionDenied unless @group == :super || @group == :user

    db_read.ro.transaction do |r|
      max = r[@user] || 0
      db_index.ro.transaction do |db|
        entries = db[:entries] || []
        entries = filter_forbidden(entries)
        size = entries.size
        entries = entries.drop_while{|e| e['id'] <= max}
        return {
          'unreads'  => entries.size,
          'comments' => size,
        }
      end
    end
  end

  private

  def filter_forbidden(entries)
    return entries.select do |e|
      @group==:super || e['user']==@user || e['acl'].include?(@group.to_s)
    end
  end

  def map_entries(entries, map)
    return entries.map do |e|
      e.merge(Hash[*map.map{|k,v| [ k, v.call(e) ]}.flatten])
    end
  end

  def load_content(type, id)
    if id.is_a?(Array)
      loader = proc{|e| load_content(type, e['id'])}
      return map_entries(id, 'content' => loader)
    end

    file = content_file(type, id)
    return unless file.exist?
    open_mode = RUBY_VERSION < '1.9.0' ? 'r' : 'r:utf-8'
    File.open(file, open_mode) {|f| f.read }
  end

  def content_file(type, id)
    return @path + [ id.to_s, type.to_s ].join('.')
  end

  def write_content(id, content)
    contents = {
      :raw  => content,
      :html => Renderer.create.render(content),
    }
    contents.each do |type, content|
      open(content_file(type, id), 'w') do |io|
        io.puts(content)
      end
    end
  end

  def delete_content(id)
    raw_file = content_file(:raw, id)
    html_file = content_file(:html, id)

    FileUtils.rm(raw_file) if File.exist?(raw_file)
    FileUtils.rm(html_file) if File.exist?(html_file)
  end

  def index_check(args)
    idx = {}
    idx['id'] = args[:id]
    idx['user'] = args[:user] if args[:user]
    idx['acl'] = args[:acl].select{|a| a=='user' || a=='other'} if args[:acl]
    idx['ref'] = args[:ref].to_i if args[:ref]
    idx['create'] = args[:create] if args[:create]
    idx['timestamp'] = Time.now.iso8601
    return idx
  end

  def content_check(args)
    content = args[:content] || ''
    size_limit = @config['size_limit'] || (1024 * 16)
    raise SizeLimitExceeded if content.length > size_limit
    return content
  end
end
