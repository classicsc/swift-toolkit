import Foundation
import UIKit
import ReadiumShared
import ReadiumNavigator
import WebKit
import ReadiumInternal

/// Information about HTML structure for highlighting purposes
public struct HtmlPositionInfo {
    public let hasRubyText: Bool
    public let htmlOffset: Int
    public let rubyAwareText: String
    public let originalText: String
    public let cssPath: String
    public let charOffset: Int
    
    public init(hasRubyText: Bool, htmlOffset: Int, rubyAwareText: String, originalText: String, cssPath: String, charOffset: Int) {
        self.hasRubyText = hasRubyText
        self.htmlOffset = htmlOffset
        self.rubyAwareText = rubyAwareText
        self.originalText = originalText
        self.cssPath = cssPath
        self.charOffset = charOffset
    }
}


open class CustomEPUBNavigatorViewController: EPUBNavigatorViewController {
    
    // Expose the current web view for coordinate conversion (read-only).
    public var currentWebView: WKWebView? {
        guard let spreadView = paginationView?.currentView as? EPUBSpreadView else {
            return nil
        }
        return spreadView.webView
    }
    
    /// Map a point (in navigator view coordinates) to a character char, string of maxChars forwardText, and Locator loc.
    public func pointToLocator(at point: CGPoint, maxChars: Int = 16) async -> (char: String?, forwardText: String?, loc: Locator?, htmlInfo: HtmlPositionInfo?) {
        guard let webView = currentWebView else {
            return (nil, nil, nil, nil)
        }
        
        // Convert the tap point from the navigator's view coordinates to the web view's coordinate system.
        let pointInWebView = view.convert(point, to: webView)
        
        // Build the JS snippet with the adjusted coordinates.
        let script = """
        (function() {
            var x = \(pointInWebView.x);
            var y = \(pointInWebView.y);
            var maxChars = \(maxChars);
            
            function generateCSSPath(node) {
                if (node.nodeType !== 3) return '';
                
                var element = node.parentElement;
                if (!element) return '';
                
                var path = [];
                
                while (element && element !== document.body) {
                    var selector = element.tagName.toLowerCase();
                    
                    if (element.id) {
                        selector += '#' + element.id;
                        path.unshift(selector);
                        break;
                    } else {
                        var siblings = Array.from(element.parentNode.children);
                        var sameTagSiblings = siblings.filter(function(sibling) {
                            return sibling.tagName === element.tagName;
                        });
                        
                        if (sameTagSiblings.length > 1) {
                            var index = sameTagSiblings.indexOf(element) + 1;
                            selector += ':nth-of-type(' + index + ')';
                        }
                        
                        path.unshift(selector);
                        element = element.parentElement;
                    }
                }
                
                return path.join(' > ');
            }
            
            function getTextNodeIndex(textNode) {
                var parent = textNode.parentNode;
                if (!parent) return 0;
                
                var textNodes = Array.from(parent.childNodes).filter(function(node) {
                    return node.nodeType === 3;
                });
                
                return textNodes.indexOf(textNode);
            }
            
            var range = document.caretRangeFromPoint(x, y);
            if (range && range.startContainer.nodeType === 3) {
                var node = range.startContainer;
                var offset = range.startOffset;
                var tappedChar = node.data.substring(offset, offset + 1);
                var surroundingText = node.data; // Full text node
                
                var before = surroundingText.substring(0, offset);
                var after = surroundingText.substring(offset + 1);
                var highlight = tappedChar;
                
                // Generate CSS path and character offset for the text node
                var cssPath = generateCSSPath(node);
                var textNodeIndex = getTextNodeIndex(node);
                if (textNodeIndex > 0) {
                    cssPath += '::text-node(' + textNodeIndex + ')';
                }
                var charOffset = offset;
                
                // Initialize variables
                var hasRubyText = false;
                var htmlOffset = offset;
                var rubyAwareText = surroundingText;
                var originalText = surroundingText;
                
                function findRubyParent(node) {
                    var current = node;
                    // Start from the text node and walk up the DOM tree
                    while (current) {
                        if (current.tagName) {
                            var tagName = current.tagName.toLowerCase();
                            if (tagName === 'ruby') {
                                return current;
                            }
                            if (tagName === 'rb') {
                                // If we're in an rb, check if its parent is ruby
                                var parent = current.parentNode;
                                if (parent && parent.tagName && parent.tagName.toLowerCase() === 'ruby') {
                                    return parent;
                                }
                            }
                        }
                        current = current.parentNode;
                    }
                    return null;
                }
                
                // Check if we're in ruby text and get the correct ruby context
                var rubyContext = null;
                var startingRubyIndex = -1;
                var rubyParent = findRubyParent(node);
                
                
                if (rubyParent) {
                    hasRubyText = true;
                    
                    // Find the paragraph or container holding multiple ruby elements
                    var container = rubyParent.parentNode;
                    while (container && container.tagName && 
                           !['p', 'div', 'span', 'body'].includes(container.tagName.toLowerCase())) {
                        container = container.parentNode;
                    }
                    
                    if (container) {
                        rubyContext = container;
                        
                        // Get original text from the entire container
                        originalText = container.textContent || '';
                        
                        // Get ruby-aware text (excluding rt elements)
                        var walker = document.createTreeWalker(
                            container,
                            NodeFilter.SHOW_TEXT,
                            {
                                acceptNode: function(textNode) {
                                    var parent = textNode.parentNode;
                                    while (parent && parent !== container) {
                                        if (parent.tagName && parent.tagName.toLowerCase() === 'rt') {
                                            return NodeFilter.FILTER_REJECT;
                                        }
                                        parent = parent.parentNode;
                                    }
                                    return NodeFilter.FILTER_ACCEPT;
                                }
                            }
                        );
                        
                        var cleanTextParts = [];
                        var textNode;
                        while (textNode = walker.nextNode()) {
                            cleanTextParts.push(textNode.textContent);
                        }
                        rubyAwareText = cleanTextParts.join('');
                        
                        // Find all ruby elements in this container
                        var rubyElements = container.getElementsByTagName('ruby');
                        for (var i = 0; i < rubyElements.length; i++) {
                            if (rubyElements[i] === rubyParent) {
                                startingRubyIndex = i;
                                break;
                            }
                        }
                        
                        // Calculate offset within the ruby-aware text
                        var beforeText = '';
                        var found = false;
                        
                        for (var i = 0; i < rubyElements.length && !found; i++) {
                            var ruby = rubyElements[i];
                            var rbElements = ruby.getElementsByTagName('rb');
                            
                            for (var j = 0; j < rbElements.length && !found; j++) {
                                var rbElement = rbElements[j];
                                var rbText = rbElement.textContent || '';
                                
                                // Check if this rb contains our tapped text node
                                var rbTextNode = rbElement.firstChild;
                                if (rbTextNode && rbTextNode.nodeType === 3 && rbTextNode === node) {
                                    htmlOffset = beforeText.length + offset;
                                    found = true;
                                    break;
                                }
                                
                                beforeText += rbText;
                            }
                        }
                    }
                }
                
                // Forward extraction starting after tapped char
                var text = '';
                var charsCollected = 0;
                
                if (hasRubyText && rubyContext && startingRubyIndex >= 0) {
                    // Ruby-aware forward text extraction
                    var rubyElements = rubyContext.getElementsByTagName('ruby');
                    
                    // Start from the current ruby element
                    for (var i = startingRubyIndex; i < rubyElements.length && charsCollected < maxChars; i++) {
                        var ruby = rubyElements[i];
                        var rbElements = ruby.getElementsByTagName('rb');
                        
                        for (var j = 0; j < rbElements.length && charsCollected < maxChars; j++) {
                            var rbText = rbElements[j].textContent || '';
                            
                            if (i === startingRubyIndex && j === 0) {
                                // For the first rb in the starting ruby, start from the tapped character
                                var rbStartIndex = rbText.indexOf(tappedChar);
                                if (rbStartIndex >= 0) {
                                    rbText = rbText.substring(rbStartIndex);
                                }
                            }
                            
                            var charsToTake = Math.min(rbText.length, maxChars - charsCollected);
                            if (charsToTake > 0) {
                                text += rbText.substring(0, charsToTake);
                                charsCollected += charsToTake;
                            }
                        }
                    }
                    
                    // Continue with non-ruby text after the last ruby element if needed
                    if (charsCollected < maxChars && startingRubyIndex < rubyElements.length) {
                        var lastRuby = rubyElements[rubyElements.length - 1];
                        var walker = document.createTreeWalker(
                            rubyContext,
                            NodeFilter.SHOW_TEXT,
                            {
                                acceptNode: function(textNode) {
                                    // Skip text nodes inside ruby or rt tags
                                    var parent = textNode.parentNode;
                                    while (parent && parent !== rubyContext) {
                                        if (parent.tagName && ['ruby', 'rt'].includes(parent.tagName.toLowerCase())) {
                                            return NodeFilter.FILTER_REJECT;
                                        }
                                        parent = parent.parentNode;
                                    }
                                    return NodeFilter.FILTER_ACCEPT;
                                }
                            }
                        );
                        
                        // Position walker after the last ruby element
                        walker.currentNode = lastRuby;
                        var textNode;
                        while ((textNode = walker.nextNode()) && charsCollected < maxChars) {
                            var remainingText = textNode.textContent || '';
                            var charsToTake = Math.min(remainingText.length, maxChars - charsCollected);
                            if (charsToTake > 0) {
                                text += remainingText.substring(0, charsToTake);
                                charsCollected += charsToTake;
                            }
                        }
                    }
                } else {
                    // Non-ruby forward text extraction (existing logic)
                    function getNextTextNode(node) {
                        var walker = document.createTreeWalker(
                            document.body,
                            NodeFilter.SHOW_TEXT,
                            {
                                acceptNode: function(node) {
                                    // Skip text nodes inside <rt> tags
                                    var parent = node.parentNode;
                                    while (parent) {
                                        if (parent.tagName && parent.tagName.toLowerCase() === 'rt') {
                                            return NodeFilter.FILTER_REJECT;
                                        }
                                        parent = parent.parentNode;
                                    }
                                    return NodeFilter.FILTER_ACCEPT;
                                }
                            }
                        );
                        
                        walker.currentNode = node;
                        return walker.nextNode();
                    }
                    
                    var currentNode = node;
                    var currentOffset = offset + 1; // Start after tapped char
                    
                    while (charsCollected < maxChars) {
                        if (currentNode && currentNode.nodeType === 3) {
                            // Get remaining text from current node
                            var remainingText = currentNode.textContent.substring(currentOffset);
                            if (remainingText.length > 0) {
                                var charsToTake = Math.min(remainingText.length, maxChars - charsCollected);
                                text += remainingText.substring(0, charsToTake);
                                charsCollected += charsToTake;
                                
                                if (charsCollected >= maxChars) break;
                            }
                        }
                        
                        // Move to next text node
                        currentNode = getNextTextNode(currentNode);
                        currentOffset = 0; // Reset offset for new nodes
                        
                        if (!currentNode) break;
                    }
                }
                
                // Trim to maxChars and stop at punctuation (e.g., 。、！？)
                text = text.substring(0, maxChars);
                var punctuationMatch = text.match(/[。、！？.,!?]/);
                if (punctuationMatch) {
                    text = text.substring(0, punctuationMatch.index + 1);
                }
                
                var forwardText = text; // text already includes tappedChar when hasRubyText is true
                if (!hasRubyText) {
                    forwardText = tappedChar + text; // Include tappedChar for non-ruby text
                }
                
                return { 
                    tappedChar: tappedChar, 
                    forwardText: forwardText, 
                    offset: offset, 
                    before: before, 
                    highlight: highlight, 
                    after: after,
                    hasRubyText: hasRubyText,
                    htmlOffset: htmlOffset,
                    rubyAwareText: rubyAwareText,
                    originalText: originalText,
                    cssPath: cssPath,
                    charOffset: charOffset
                };
            }
            return null;
        })();
        """
        
        // Evaluate the script on the current resource's web view.
        let result = await evaluateJavaScript(script)
        guard case let .success(jsonAny) = result, let json = jsonAny as? [String: Any] else {
            return (nil, nil, nil, nil)
        }
        
        let tappedChar = json["tappedChar"] as? String
        let forwardText = json["forwardText"] as? String
        let offset = json["offset"] as? Int ?? 0
        let before = json["before"] as? String
        let highlight = json["highlight"] as? String
        let after = json["after"] as? String
        
        // Extract HTML structure information
        let hasRubyText = json["hasRubyText"] as? Bool ?? false
        let htmlOffset = json["htmlOffset"] as? Int ?? offset
        let rubyAwareText = json["rubyAwareText"] as? String ?? ""
        let originalText = json["originalText"] as? String ?? ""
        let cssPath = json["cssPath"] as? String ?? ""
        let charOffset = json["charOffset"] as? Int ?? offset
        
        // Construct Locator if possible (fall back to currentLocation if failed).
        guard let href = currentLocation?.href else {
            return (tappedChar, forwardText, currentLocation, nil)
        }
        
        let text = Locator.Text(after: after, before: before, highlight: highlight)
        
        let locator = Locator(
            href: href,
            mediaType: MediaType.xhtml,
            text: text
        )
        
        // Create HTML position info
        let htmlInfo = HtmlPositionInfo(
            hasRubyText: hasRubyText,
            htmlOffset: htmlOffset,
            rubyAwareText: rubyAwareText,
            originalText: originalText,
            cssPath: cssPath,
            charOffset: charOffset
        )
        
        return (tappedChar, forwardText, locator, htmlInfo)
    }
}
