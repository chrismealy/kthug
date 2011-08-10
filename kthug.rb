#!/usr/bin/env ruby

require 'rubygems'
require 'daemons'
require 'nokogiri'
require 'active_support/core_ext/numeric/time'
require 'active_support/core_ext/hash/conversions'
require 'open-uri'
require 'redis'
require 'redis/objects'
require 'redis/sorted_set'
require 'redis/hash_key'
require 'logger'
require 'pp'
require 'json'

class Kthug
  def initialize(options = {})
    @options = options
    @times = Redis::SortedSet.new('kthug-times')
    @posts = Redis::HashKey.new('kthug-posts', marshal: true)
  end

  def test?
    @options[:test]
  end

  def update
    feed.css('item').each { |item| save_item item }

    update_rss
  end

  def feed
    Nokogiri::XML(open('http://krugman.blogs.nytimes.com/feed/')) {|c| c.default_xml.noblanks }
  end

  def save_item(item)
    url = item_url item

    if @times.rank(url)
      page = Nokogiri::HTML(download(url)) {|c| c.default_xml.noblanks }

      @times[url] = item_time item

      @posts[url] = {
        title: page.at('.entry-title').content,
        subhead: item.at('description').content,
        content: page.at('.entry-content').children.to_s
      }
    end
  end

  def item_url(item)
    item.at('link').content
  end

  def item_time(item)
    Time.parse(item.at('pubDate').content.gsub('+000', 'UTC')).to_i
  end

  def download(url)
    file = cache_filename url

    if test? and File.exists?(file) and File.size(file) > 0
      content = open(file).read
    else
      content = open(url).read
      File.open(file, 'wb') {|f| f.write(content) }
    end

    content
  end

  def cache_filename(url)
    '/tmp/' + url.gsub('/', '-')
  end

  def update_rss
    File.open('/tmp/kthug.atom', 'w') {|f| f.write(atom_feed) }
  end

  def atom_feed
    # <entry>
    #         <title>Atom-Powered Robots Run Amok</title>
    #         <link href="http://example.org/2003/12/13/atom03" />
    #         <link rel="alternate" type="text/html" href="http://example.org/2003/12/13/atom03.html"/>
    #         <link rel="edit" href="http://example.org/2003/12/13/atom03/edit"/>
    #         <id>urn:uuid:1225c695-cfb8-4ebb-aaaa-80da344efa6a</id>
    #         <updated>2003-12-13T18:30:02Z</updated>
    #         <summary>Some text.</summary>
    # </entry>

    builder = Nokogiri::XML::Builder.new do |xml|
      xml.feed(xmlns: "http://www.w3.org/2005/Atom") {
        xml.title "Kthug"
        @times.revrange(0, 19).each { |url|
          post = @posts[url]
          xml.entry {
            xml.title post[:title]
            xml.link(href: url)
            xml.content(type: 'xhtml') {
              xml.p { xml.i post[:subhead] }
              xml << post[:content]
            }
          }
        }
      }
    end

    return builder.to_xml
  end

end

$redis = Redis.new(:host => 'localhost', :port => 6379)
$redis.client.logger = Logger.new(STDOUT)


if ARGV.first == 'test'
  Kthug.new(test: false).update
else
  kthug = Kthug.new

  Daemons.run_proc('kthug', log_output: true) do
    loop do
      kthug.update
      sleep 5.seconds
    end
  end
end
