package org.project.exception;

import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.web.access.AccessDeniedHandler;

import javax.servlet.RequestDispatcher;
import javax.servlet.ServletException;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.IOException;

public class CustomAccessDeniedException implements AccessDeniedHandler {

    @Override
    public void handle(HttpServletRequest request, HttpServletResponse response, AccessDeniedException ade) throws IOException, ServletException {

        RequestDispatcher requestDispatcher = request.getRequestDispatcher("/WEB-INF/views/error.jsp");
        response.setStatus(HttpServletResponse.SC_FORBIDDEN);
        request.setAttribute("code", "403 / Forbidden");
        // A fixed text: the message of the exception comes in the language of the browser
        request.setAttribute("message", "Access is denied");
        requestDispatcher.forward(request, response);

    }
}