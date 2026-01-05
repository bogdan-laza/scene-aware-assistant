import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable } from 'rxjs';

@Injectable({
  providedIn: 'root'
})
export class VisionService {
  private http = inject(HttpClient);

  private readonly API_URL = 'http://localhost:8000';

  /**
   * Main entry point.
   * Routes the request to the correct specific function based on detectionType.
   */
  analyzeImage(file: File, type: string): Observable<any> {
    switch (type) {
      case 'Obstacles':
        return this.detectObstacles(file);
      case 'Crosswalk':
        return this.detectCrosswalk(file);
      case 'Custom':
        return this.customAnalysis(file, 'Describe this image in detail.');
      default:
        throw new Error(`Unknown detection type: ${type}`);
    }
  }

  private detectObstacles(file: File): Observable<any> {
    const formData = new FormData();
    formData.append('file', file);

    return this.http.post(`${this.API_URL}/obstacles`, formData);
  }

  private detectCrosswalk(file: File): Observable<any> {
    const formData = new FormData();
    formData.append('file', file);

    return this.http.post(`${this.API_URL}/crosswalk`, formData);
  }

  private customAnalysis(file: File, promptText: string): Observable<any> {
    const formData = new FormData();
    formData.append('file', file);
    formData.append('prompt', promptText);

    return this.http.post(`${this.API_URL}/custom`, formData);
  }
}
