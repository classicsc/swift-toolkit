import Foundation
import UIKit
import ReadiumShared
import ReadiumNavigator
import WebKit
import ReadiumInternal


open class CustomEPUBNavigatorViewController: EPUBNavigatorViewController {
    
    // Expose the current web view for coordinate conversion (read-only).
    public var currentWebView: WKWebView? {
        guard let spreadView = paginationView?.currentView as? EPUBSpreadView else {
            return nil
        }
        return spreadView.webView
    }
    
    /// Map a point (in navigator view coordinates) to a character char, string of maxChars forwardText, and Locator loc.
    public func pointToLocator(at point: CGPoint, maxChars: Int = 16) async -> (char: String?, forwardText: String?, loc: Locator?) {
        guard let webView = currentWebView else {
            return (nil, nil, nil)
        }
        
        // Convert the tap point from the navigator's view coordinates to the web view's coordinate system.
        let pointInWebView = view.convert(point, to: webView)
        
        // Build the JS snippet with the adjusted coordinates.
        let script = """
        (function() {
            var x = \(pointInWebView.x);
            var y = \(pointInWebView.y);
            var maxChars = \(maxChars);
            var range = document.caretRangeFromPoint(x, y);
            if (range && range.startContainer.nodeType === 3) {
                var node = range.startContainer;
                var offset = range.startOffset;
                var tappedChar = node.data.substring(offset, offset + 1);
                var surroundingText = node.data; // Full text node
                
                var before = surroundingText.substring(0, offset);
                var after = surroundingText.substring(offset + 1);
                var highlight = tappedChar;
                
                // Helper function to get next text node
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
                
                // Forward extraction starting after tapped char
                var text = '';
                var charsCollected = 0;
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
                
                // Trim to maxChars and stop at punctuation (e.g., 。、！？)
                text = text.substring(0, maxChars);
                var punctuationMatch = text.match(/[。、！？.,!?]/);
                if (punctuationMatch) {
                    text = text.substring(0, punctuationMatch.index + 1);
                }
                
                var forwardText = tappedChar + text; // Include tappedChar
                
                return { tappedChar: tappedChar, forwardText: forwardText, offset: offset, before: before, highlight: highlight, after: after };
            }
            return null;
        })();
        """
        
        // Evaluate the script on the current resource's web view.
        let result = await evaluateJavaScript(script)
        guard case let .success(jsonAny) = result, let json = jsonAny as? [String: Any] else {
            return (nil, nil, nil)
        }
        
        let tappedChar = json["tappedChar"] as? String
        let forwardText = json["forwardText"] as? String
        let offset = json["offset"] as? Int ?? 0
        let before = json["before"] as? String
        let highlight = json["highlight"] as? String
        let after = json["after"] as? String
        
        // Construct Locator if possible (fall back to currentLocation if failed).
        guard let href = currentLocation?.href else {
            return (tappedChar, forwardText, currentLocation)
        }
        
        let text = Locator.Text(after: after, before: before, highlight: highlight)
        
        let locator = Locator(
            href: href,
            mediaType: MediaType.xhtml,
            text: text
        )
        
        return (tappedChar, forwardText, locator)
    }
}
