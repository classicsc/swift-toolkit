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
                
                // Forward extraction starting after tapped char
                var text = '';
                var current = node;
                var charsCollected = 0;
                var localOffset = offset + 1; // Start after tapped char
                
                while (current && charsCollected < maxChars) {
                    if (current.nodeType === 3) { // Text node
                        var nodeText = current.textContent.substring(localOffset);
                        text += nodeText;
                        charsCollected += nodeText.length;
                        localOffset = 0; // Reset for next nodes
                    } else if (current.nodeType === 1) { // Element
                        // Skip <rt> (ruby annotations)
                        if (current.tagName.toLowerCase() === 'rt') {
                            current = current.nextSibling;
                            continue;
                        }
                        // Traverse children
                        current = current.firstChild || current.nextSibling;
                        continue;
                    }
                    // Move to next
                    if (current.nextSibling) {
                        current = current.nextSibling;
                    } else {
                        while (current.parentNode && !current.parentNode.nextSibling) {
                            current = current.parentNode;
                        }
                        current = current.parentNode ? current.parentNode.nextSibling : null;
                    }
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
