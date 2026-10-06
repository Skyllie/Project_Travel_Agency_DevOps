# Travel Agency project

<img src="./images/04.png" style="width: 600px; height: 350px;"><br>
<br>

## Project Overview

This project is a web application for a travel agency, allowing users to find and book hotels in various countries.
It has a separate managerial role that can add hotels and rooms to the system and view all users and their orders.
The application is built using Maven, Hibernate, Spring MVC (Thymeleaf or JSP + JSTL), and Spring Security.

<img src="./images/01.png" style="width: 600px; height: 300px;"><br>
<img src="./images/02.png" style="width: 600px; height: 300px;"><br>
<img src="./images/03.png" style="width: 600px; height: 300px;"><br>
<img src="./images/05.png" style="width: 600px; height: 300px;"><br>
<img src="./images/06.png" style="width: 600px; height: 300px;"><br>

## If you log in as an administrator, you can

<img src="./images/07.png" style="width: 600px; height: 300px;"><br>
<img src="./images/08.png" style="width: 600px; height: 300px;"><br>
<img src="./images/09.png" style="width: 600px; height: 300px;"><br>
<img src="./images/10.png" style="width: 600px; height: 300px;"><br>
<img src="./images/11.png" style="width: 600px; height: 300px;"><br>
<img src="./images/12.png" style="width: 600px; height: 300px;"><br>
<img src="./images/13.png" style="width: 600px; height: 300px;"><br>
<br>

## Technologies

- Java
- Maven
- Hibernate
- Spring MVC
- Thymeleaf
- Spring Security
- IntelliJ (IDE)
- MySQL

### Technical Details

- **Programming Language back-end:** Java
- **Database:** MySql
- **Required Tools:** Java 17, Maven 3.6.3

### Running the Project

1. **Build the Project:**
   Execute the following command in the `TravelAgency` directory:
```bash
mvn clean package
```

2. **Run the Project:**

After successful building, move the .war file in the Apache TomCat:

```text
   The application will start on 8080 port.
```

* **Database Configuration**

In the application's configuration file (application.properties), the path and connection data to the database are obtained from the following environment variables:

    DB_TRAVELAGENCY_URL
    DB_TRAVELAGENCY_USER
    DB_TRAVELAGENCY_PASSWORD

Before running, ensure that the MySql database contains a database, for example travelagency.

Wishing you success with the "Travel Agency" project!

---
